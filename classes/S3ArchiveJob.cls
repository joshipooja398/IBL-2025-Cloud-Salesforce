public class S3ArchiveJob implements Queueable, Database.AllowsCallouts {
    // ====== CONFIG ======
    private static final String REGION = 'ap-southeast-2';        // must match your Named Credential region
    private static final Integer CHUNK_BYTES = 5 * 1024 * 1024;   // 5 MB
    private static final Integer MAX_PARTS_THIS_RUN = 40;         // tune for callout limits
    private static final String NC_NAME = 'AWS_S3_Service';       // your Named Credential label

    // ====== WORK STATE (primitives only so chaining stays lightweight) ======
    Id listingId;
    Id contentDocumentId;
    Id contentVersionId;
    String bucket;                // single org bucket
    String s3Key;                 // <PropertyId>/<ListingId>/<ContentDocumentId>/<title>.<ext>
    String uploadId;              // S3 multipart upload id
    Integer nextStart = 0;        // next byte to read from SF
    Integer partNumber = 1;       // next part number for S3
    Integer totalSize = null;     // total bytes; learned from Content-Range
    String partsCsv = '';         // "pn:etag,pn:etag,..." compact ETag storage

    // Kickoff ctor (called by your controller/launcher)
    public S3ArchiveJob(Id contentDocumentId, Id listingId) {
        this.contentDocumentId = contentDocumentId;
        this.listingId = listingId;
    }

    // Chaining ctor (internal)
    public S3ArchiveJob(
        Id contentDocumentId, Id listingId,
        String bucket, String s3Key, String uploadId,
        Integer nextStart, Integer partNumber, Integer totalSize,
        String partsCsv, Id contentVersionId
    ) {
        this.contentDocumentId = contentDocumentId;
        this.listingId         = listingId;
        this.bucket            = bucket;
        this.s3Key             = s3Key;
        this.uploadId          = uploadId;
        this.nextStart         = (nextStart == null) ? 0 : nextStart;
        this.partNumber        = (partNumber == null) ? 1 : partNumber;
        this.totalSize         = totalSize;
        this.partsCsv          = (partsCsv == null) ? '' : partsCsv;
        this.contentVersionId  = contentVersionId;
    }

    // ====== MAIN ======
    public void execute(QueueableContext qc) {
        // --- time-slice so we never exceed async callout/CPU limits ---
        final Long T_START = DateTime.now().getTime();
        final Long MAX_MS_THIS_RUN = 90 * 1000; // ~90s
        final Integer MAX_PARTS_PER_RUN = 10;   // ≈20 callouts/run (GET+PUT)

        List<RemSuite__Media__c> mediaList = new List<RemSuite__Media__c>();

        // 1) Single bucket derived from org name (sanitized + short org id suffix)
        if (bucket == null) {
            bucket = bucketFromOrg();
            ensureBucketExists(bucket);
        }

        // 2) Resolve latest ContentVersion and build S3 key
        if (contentVersionId == null || s3Key == null || totalSize == null) 
        {
            RemSuite__PropertyListing__c listing = [
                SELECT Name,RemSuite__Property__c,RemSuite__Property__r.Name
                FROM RemSuite__PropertyListing__c
                WHERE Id = :listingId
                LIMIT 1
            ];
            Id propertyId = listing.RemSuite__Property__c;

            ContentVersion cv = [
                SELECT Id, Title, FileExtension, ContentSize, RemSuite__Portal_Use__c 
                FROM ContentVersion
                WHERE ContentDocumentId = :contentDocumentId
                ORDER BY VersionNumber DESC
                LIMIT 1
            ];

        // Get the linked entities for this ContentDocument
            List<ContentDocumentLink> links = [
                SELECT LinkedEntityId, LinkedEntity.Name
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :contentDocumentId
            ];

            for (ContentDocumentLink link : links) {
                if (link.LinkedEntityId.getSObjectType() == RemSuite__Media__c.SObjectType) {
                    RemSuite__Media__c media = [
                        SELECT Id, RemSuite__Floorplan__c, RemSuite__Statement_of_Information__c, RemSuite__Portal_Available__c
                        FROM RemSuite__Media__c
                        WHERE Id = :link.LinkedEntityId
                        LIMIT 1
                    ];
                    mediaList.add(media);
                }
            }
            String preText = '';

            if (!mediaList.isEmpty()) {
                RemSuite__Media__c media = mediaList[0];
                preText = (media.RemSuite__Floorplan__c ? 'floorplan_' : '') +
                (media.RemSuite__Statement_of_Information__c ? 'statement_of_information_' : '') +
                (media.RemSuite__Portal_Available__c ? 'portal_available_' : '');
            }

            contentVersionId = cv.Id;
            totalSize = Integer.valueOf(cv.ContentSize);

            String ext = String.isBlank(cv.FileExtension) ? 'bin' : cv.FileExtension.toLowerCase();
            String safeTitle = sanitizeForKey(cv.Title);
            String propertyName = sanitizeForKey(listing.RemSuite__Property__r.Name);
            String listingAutoNumber = sanitizeForKey(listing.Name);
        
            s3Key = getFilePath(String.valueOf(propertyId),propertyName,String.valueOf(listingId),listingAutoNumber)+preText+safeTitle+'.'+ext;
        }
    
        // 3) If file is <= 5MB, do a single PUT and finish
        if (totalSize <= CHUNK_BYTES) {
            // GET whole body once via Shepherd
            HttpRequest g = new HttpRequest();
            g.setMethod('GET');
            g.setEndpoint(URL.getOrgDomainUrl().toExternalForm() +
                '/sfc/servlet.shepherd/version/download/' + contentVersionId);
            g.setCompressed(false);
            g.setHeader('Accept','application/octet-stream');
            g.setHeader('Accept-Encoding','identity');
            g.setHeader('Authorization','Bearer ' + UserInfo.getSessionId());
            g.setTimeout(120000);

            HttpResponse gr = new Http().send(g);
            Integer sc = gr.getStatusCode();
            // Shepherd may 301/302 to documentforce host
            if (sc == 301 || sc == 302 || sc == 307 || sc == 308) {
                String loc = gr.getHeader('Location');
                if (String.isBlank(loc)) throw new CalloutException('Redirect without Location (small file).');
                HttpRequest g2 = new HttpRequest();
                g2.setMethod('GET');
                g2.setEndpoint(loc);
                g2.setCompressed(false);
                g2.setHeader('Accept','application/octet-stream');
                g2.setHeader('Accept-Encoding','identity');
                g2.setHeader('Authorization','Bearer ' + UserInfo.getSessionId());
                g2.setTimeout(120000);
                gr = new Http().send(g2);
                sc = gr.getStatusCode();
            }
            if (sc != 200) throw new CalloutException('Small-file GET failed: ' + sc + ' ' + gr.getStatus());
            Blob body = gr.getBodyAsBlob();
            if (body == null) throw new CalloutException('Small-file GET returned empty body.');

            HttpRequest p = new HttpRequest();
            p.setMethod('PUT');
            p.setEndpoint(awsBase() + '/' + EncodingUtil.urlEncode(bucket,'UTF-8') + '/' + urlKey(s3Key));
            p.setHeader('Content-Type','application/octet-stream');
            p.setHeader('x-amz-content-sha256','UNSIGNED-PAYLOAD');
            p.setBodyAsBlob(body);
            p.setTimeout(120000);
            HttpResponse pr = new Http().send(p);
            if (pr.getStatusCode() != 200) {
                throw new CalloutException('PUT small object failed: ' + pr.getStatus() + ' ' + pr.getBody());
            }
            deleteConDoc(contentDocumentId);
            return; // done
        }

        // 4) Start multipart if needed
        if (uploadId == null) {
            uploadId = initiateMultipart(bucket, s3Key);
        }

        // 5) Range-GET in chunks from Salesforce → upload parts to S3
        Integer partsDone = 0;
        try {
            while (partsDone < MAX_PARTS_PER_RUN) {
                if (nextStart >= totalSize) break;
                if (DateTime.now().getTime() - T_START > MAX_MS_THIS_RUN) break;

                Integer endChunk = Math.min(nextStart + CHUNK_BYTES, totalSize) - 1;

                // First request to Shepherd on My Domain
                HttpRequest getReq = new HttpRequest();
                getReq.setMethod('GET');
                getReq.setEndpoint(
                    URL.getOrgDomainUrl().toExternalForm() +
                    '/sfc/servlet.shepherd/version/download/' + contentVersionId
                );
                getReq.setCompressed(false);
                getReq.setHeader('Accept', 'application/octet-stream');
                getReq.setHeader('Accept-Encoding', 'identity');
                getReq.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
                getReq.setHeader('Range', 'bytes=' + nextStart + '-' + endChunk);
                getReq.setTimeout(120000);

                Http http = new Http();
                HttpResponse getRes = http.send(getReq);

                Integer sc = getRes.getStatusCode();

                // Follow redirect manually if needed
                if (sc == 301 || sc == 302 || sc == 307 || sc == 308) {
                    String loc = getRes.getHeader('Location');
                    if (String.isBlank(loc)) {
                        abortMultipart(bucket, s3Key, uploadId);
                        throw new CalloutException('Redirect without Location header.');
                    }
                    HttpRequest getReq2 = new HttpRequest();
                    getReq2.setMethod('GET');
                    getReq2.setEndpoint(loc);
                    getReq2.setCompressed(false);
                    getReq2.setHeader('Accept', 'application/octet-stream');
                    getReq2.setHeader('Accept-Encoding', 'identity');
                    getReq2.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
                    getReq2.setHeader('Range', 'bytes=' + nextStart + '-' + endChunk);
                    getReq2.setTimeout(120000);

                    getRes = http.send(getReq2);
                    sc = getRes.getStatusCode();
                }

                // Must be partial content
                if (sc != 206) {
                    abortMultipart(bucket, s3Key, uploadId);
                    throw new CalloutException(
                        'Expected 206 Partial Content but got ' + sc +
                        ' Range=' + nextStart + '-' + endChunk +
                        ' Location=' + getRes.getHeader('Location')
                    );
                }

                Blob chunk = getRes.getBodyAsBlob();
                if (chunk == null || chunk.size() == 0) {
                    abortMultipart(bucket, s3Key, uploadId);
                    throw new CalloutException('Empty chunk for range ' + nextStart + '-' + endChunk);
                }

                Boolean isFinalPart = (nextStart + chunk.size() >= totalSize);
                if (!isFinalPart && chunk.size() < CHUNK_BYTES) {
                    abortMultipart(bucket, s3Key, uploadId);
                    throw new CalloutException('Non-final part smaller than 5 MB.');
                }

                String etag = uploadPart(bucket, s3Key, uploadId, partNumber, chunk);
                if (!String.isBlank(partsCsv)) partsCsv += ',';
                partsCsv += String.valueOf(partNumber) + ':' + etag;

                nextStart += chunk.size();
                partNumber++;
                partsDone++;
            }
        } catch (Exception e) {
            if (uploadId != null) abortMultipart(bucket, s3Key, uploadId);
            throw e;
        }

        // 6) Finish or chain a fresh instance
        if (nextStart >= totalSize) {
            completeMultipart(bucket, s3Key, uploadId, partsCsv);
            deleteConDoc(contentDocumentId);
        } else {
            System.enqueueJob(new S3ArchiveJob(
                contentDocumentId, listingId,
                bucket, s3Key, uploadId,
                nextStart, partNumber, totalSize,
                partsCsv, contentVersionId
            ));
        }
    }

    public static void deleteConDoc(String conDocId) {
        // Query the ContentDocument (make sure it exists)
        ContentDocument doc = [
            SELECT Id
            FROM ContentDocument
            WHERE Id = :conDocId
            LIMIT 1
        ];

        // Find related Media via ContentDocumentLink
        List<ContentDocumentLink> links = [
            SELECT LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :conDocId
        ];

        List<RemSuite__Media__c> mediaToDelete = new List<RemSuite__Media__c>();
        for (ContentDocumentLink link : links) {
            if (link.LinkedEntityId.getSObjectType() == RemSuite__Media__c.SObjectType) {
                mediaToDelete.add(
                    [SELECT Id FROM RemSuite__Media__c WHERE Id = :link.LinkedEntityId LIMIT 1]
                );
            }
        }
        // Delete the ContentDocument (this cascades versions)
        delete doc;

        // Delete related Media records if found
        if (!mediaToDelete.isEmpty()) {
            delete mediaToDelete;
        }

        // Publish platform event for refresh
        Refresh_Listing_Page__e evt = new Refresh_Listing_Page__e();
        Database.SaveResult sr = EventBus.publish(evt);

        System.debug('PLATFORM event published? ' + sr.isSuccess());
        if (!sr.isSuccess()) {
            System.debug('Failed to publish Refresh_Listing_Page__e event: ' + sr.getErrors()[0].getMessage());
        }
    }

    // ====== BUCKET HELPERS ======
    private static Boolean bucketExists(String bucketName) {
        HttpRequest r = new HttpRequest();
        r.setMethod('HEAD');
        r.setEndpoint(awsBase() + '/' + EncodingUtil.urlEncode(bucketName, 'UTF-8'));
        r.setTimeout(60000);
        HttpResponse res = new Http().send(r);
        Integer code = res.getStatusCode();
        if (code == 200) return true;
        if (code == 404) return false;
        if (code == 403) throw new CalloutException('Access denied to S3 bucket "' + bucketName + '". Check IAM.');
        throw new CalloutException('HeadBucket unexpected HTTP ' + code + ': ' + res.getStatus());
    }

    private static void createBucket(String bucketName) {
        Boolean isUsEast1 = REGION == 'us-east-1';
        String body = isUsEast1 ? '' :
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">' +
            '<LocationConstraint>' + REGION + '</LocationConstraint>' +
            '</CreateBucketConfiguration>';

        HttpRequest r = new HttpRequest();
        r.setMethod('PUT'); // PUT Bucket
        r.setEndpoint(awsBase() + '/' + EncodingUtil.urlEncode(bucketName, 'UTF-8'));
        if (!isUsEast1) {
            r.setHeader('Content-Type', 'application/xml');
            r.setBody(body);
        }
        r.setTimeout(60000);
        HttpResponse res = new Http().send(r);
        Integer code = res.getStatusCode();

        if (code == 200 || code == 202) return;
        if (code == 409) {
            String b = res.getBody() == null ? '' : res.getBody();
            if (b.contains('BucketAlreadyOwnedByYou')) return;
            if (b.contains('BucketAlreadyExists')) {
                throw new CalloutException('Bucket name "' + bucketName + '" is already taken globally.');
            }
        }
        if (code == 400) throw new CalloutException('CreateBucket failed 400: check REGION vs Named Credential region.');
        throw new CalloutException('CreateBucket failed HTTP ' + code + ': ' + res.getStatus());
    }

    private static void ensureBucketExists(String bucketName) {
        if (!bucketExists(bucketName)) createBucket(bucketName);
    }

    // Build a globally-unique, S3-safe bucket name from org name + short org id suffix
    public static String bucketFromOrg() {
        Organization o = [SELECT Name FROM Organization LIMIT 1];
        String base = sanitizeBucket(o.Name);
        String orgSuffix = UserInfo.getOrganizationId().right(6).toLowerCase();
        String candidate = base + '-' + orgSuffix;

        if (candidate.length() > 63) {
            candidate = candidate.substring(0, 63);
            while (candidate.length() > 0 && !Pattern.compile('[a-z0-9]$').matcher(candidate).find()) {
                candidate = candidate.substring(0, candidate.length() - 1);
            }
            if (candidate.length() < 3) candidate = 'org-' + orgSuffix;
        }
        return candidate;
    }

    // S3 bucket naming rules: lowercase letters, digits, dots, hyphens; 3–63; start/end alnum
    public static String sanitizeBucket(String s) {
        if (String.isBlank(s)) return 'org';
        s = s.toLowerCase();
        s = s.replaceAll('[^a-z0-9.-]', '-');   // only a-z 0-9 . -
        s = s.replaceAll('[-.]{2,}', '-');      // collapse repeats
        s = s.replaceAll('^[^a-z0-9]+', '');    // trim invalid start
        s = s.replaceAll('[^a-z0-9]+$', '');    // trim invalid end
        if (s.length() < 3) s = (s + '-org').substring(0, Math.min(3, (s + '-org').length()));
        return s;
    }

    // ====== S3 MULTIPART HELPERS ======
    private static String awsBase() { return 'callout:' + NC_NAME; }

    private static String urlKey(String key){
        return EncodingUtil.urlEncode(key,'UTF-8').replace('+','%20').replace('%2F','/');
    }
    
    private static String parseBetween(String s, String a, String b){
        Integer i = s.indexOf(a); if (i<0) return null;
        Integer j = s.indexOf(b, i + a.length()); if (j<0) return null;
        return s.substring(i + a.length(), j);
    }

    public static string getFilePath(String propertyId,String propertyName, String listingId, String listingAutoNumber){
            String s3Key ='';
            s3Key =  propertyName+'.'+String.valueOf(propertyId)+ '/' +
            listingAutoNumber+'.'+String.valueOf(listingId) + '/';
            return s3Key;
    }


    private static String initiateMultipart(String bucketName, String key) {
        HttpRequest r = new HttpRequest();
        r.setMethod('POST');
        r.setEndpoint(awsBase() + '/' + EncodingUtil.urlEncode(bucketName,'UTF-8') + '/' + urlKey(key) + '?uploads');
        r.setHeader('x-amz-content-sha256', 'UNSIGNED-PAYLOAD');
        r.setTimeout(120000);
        HttpResponse res = new Http().send(r);

        if (res.getStatusCode() == 200) {
            String id = parseBetween(res.getBody(), '<UploadId>', '</UploadId>');
            if (id == null) throw new CalloutException('InitiateMultipart missing UploadId. Body: ' + res.getBody());
            return id;
        }
        if (res.getStatusCode() == 404 && (res.getBody() + '').contains('NoSuchBucket')) {
            throw new CalloutException('S3 bucket "' + bucketName + '" does not exist or is not accessible.');
        }
        if (res.getStatusCode() == 301) {
            String br = res.getHeader('x-amz-bucket-region');
            throw new CalloutException('Bucket region mismatch. Bucket is in "' + br + '". Update Named Credential region.');
        }
        throw new CalloutException('S3 initiate failed: ' + res.getStatus() + ' ' + res.getBody());
    }

    private static String uploadPart(String bucketName, String key, String uploadId, Integer partNo, Blob body) {
        HttpRequest r = new HttpRequest();
        r.setMethod('PUT');
        r.setEndpoint(
            awsBase() + '/' +
            EncodingUtil.urlEncode(bucketName,'UTF-8') + '/' +
            urlKey(key) +
            '?partNumber=' + partNo + '&uploadId=' + EncodingUtil.urlEncode(uploadId,'UTF-8')
        );
        // SigV4 with binary body: don't set Content-Length; mark as unsigned payload
        r.setHeader('Content-Type', 'application/octet-stream');
        r.setHeader('x-amz-content-sha256', 'UNSIGNED-PAYLOAD');

        r.setBodyAsBlob(body);
        r.setTimeout(120000);

        HttpResponse res = new Http().send(r);
        Integer code = res.getStatusCode();
        if (code != 200) {
            String b = res.getBody();
            if (b != null && b.length() > 600) b = b.substring(0, 600) + '...';
            throw new CalloutException('UploadPart #' + partNo + ' failed: HTTP ' + code + ' ' + res.getStatus() + ' | ' + b);
        }
        String etag = res.getHeader('ETag');
        if (etag == null) throw new CalloutException('UploadPart #' + partNo + ' succeeded but missing ETag header.');
        return etag.replace('"','');
    }

    private static void completeMultipart(String bucketName, String key, String uploadId, String partsCsv) {
        String xml = buildCompleteXml(partsCsv);
        HttpRequest r = new HttpRequest();
        r.setMethod('POST');
        r.setEndpoint(awsBase() + '/' + EncodingUtil.urlEncode(bucketName,'UTF-8') + '/' + urlKey(key)
                      + '?uploadId=' + EncodingUtil.urlEncode(uploadId,'UTF-8'));
        r.setHeader('Content-Type','application/xml');
        r.setHeader('x-amz-content-sha256', 'UNSIGNED-PAYLOAD');
        r.setBody(xml);
        r.setTimeout(120000);
        HttpResponse res = new Http().send(r);
        if (res.getStatusCode() != 200) {
            throw new CalloutException('CompleteMultipart failed: ' + res.getStatus() + ' ' + res.getBody());
        }
    }

    private static void abortMultipart(String bucketName, String key, String uploadId) {
        try {
            HttpRequest r = new HttpRequest();
            r.setMethod('DELETE');
            r.setEndpoint(awsBase() + '/' + EncodingUtil.urlEncode(bucketName,'UTF-8') + '/' + urlKey(key)
                          + '?uploadId=' + EncodingUtil.urlEncode(uploadId,'UTF-8'));
            r.setHeader('x-amz-content-sha256', 'UNSIGNED-PAYLOAD');
            r.setTimeout(60000);
            new Http().send(r);
        } catch (Exception ignore) {}
    }

    // Build <CompleteMultipartUpload> xml from "pn:etag,..." CSV
    private static String buildCompleteXml(String partsCsv) {
        String xml = '<CompleteMultipartUpload>';
        if (!String.isBlank(partsCsv)) {
            for (String token : partsCsv.split(',')) {
                List<String> pe = token.split(':');
                Integer pn = Integer.valueOf(pe[0]);
                String et = pe[1];
                xml += '<Part><PartNumber>' + pn + '</PartNumber><ETag>' + et + '</ETag></Part>';
            }
        }
        xml += '</CompleteMultipartUpload>';
        return xml;
    }

    // ====== MISC ======
    public static String sanitizeForKey(String s) {
        if (String.isBlank(s)) return 'file';
        String out = '';
        for (Integer i = 0; i < s.length(); i++) {
            String c = s.substring(i, i + 1);
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                c == '_' || c == '-' || c == '.') out += c;
            else out += '_';
        }
        return out;
    }
}