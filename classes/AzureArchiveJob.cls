public class AzureArchiveJob implements Queueable, Database.AllowsCallouts {
    // ====== CONFIG ======
    private static final String STORAGE_ACCOUNT = 'remsuitetest';                      // Azure storage account
    private static final String CONTAINER_NAME  = 'remsuite-client-container';         // Azure container
    private static final Integer CHUNK_BYTES   = 4 * 1024 * 1024;                      // 4 MB chunk
    private static final Integer MAX_BLOCKS_PER_RUN = 10;                             // blocks per queue run
    private static final String SAS_TOKEN      = 'sp=racwdl&st=2025-09-15T01:25:53Z&se=2025-11-01T08:40:53Z&spr=https&sv=2024-11-04&sr=c&sig=e16qgGt%2Fghc7b3Hxa0OUNbFIul4XqbM1TTqc06E0hWY%3D';

    // ====== WORK STATE (primitive-only so chaining stays lightweight) ======
    Id listingId;
    Id contentDocumentId;
    Id contentVersionId;
    String container = CONTAINER_NAME;
    String blobName;            // path/filename in container
    Integer nextStart = 0;      // next byte offset to read from Salesforce
    Integer blockNumber = 1;    // next block number
    Integer totalSize = null;   // total bytes in file
    String blockIdsCsv = '';    // comma-separated base64 block ids in upload order
    Boolean isFloorplan = false;
    Boolean isStatement = false;
    Boolean isPortal = false;

    // Kickoff ctor (called by controller/launcher)
    public AzureArchiveJob(Id contentDocumentId, Id listingId) {
        this.contentDocumentId = contentDocumentId;
        this.listingId = listingId;
    }

    // Chaining ctor (internal)
    public AzureArchiveJob(
        Id contentDocumentId, Id listingId,
        String blobName,
        Integer nextStart, Integer blockNumber, Integer totalSize,
        String blockIdsCsv, Id contentVersionId
    ) {
        this.contentDocumentId = contentDocumentId;
        this.listingId = listingId;
        this.blobName = blobName;
        this.nextStart = (nextStart == null) ? 0 : nextStart;
        this.blockNumber = (blockNumber == null) ? 1 : blockNumber;
        this.totalSize = totalSize;
        this.blockIdsCsv = (blockIdsCsv == null) ? '' : blockIdsCsv;
        this.contentVersionId = contentVersionId;
    }

    // ====== MAIN ======
    public void execute(QueueableContext qc) {
        final Long T_START = DateTime.now().getTime();
        final Long MAX_MS_THIS_RUN = 90 * 1000; // ~90s
        final Integer MAX_BLOCKS_THIS_RUN = MAX_BLOCKS_PER_RUN;

        try {
            // 1) Resolve ContentVersion, build blobName and totalSize if first run
            if (contentVersionId == null || blobName == null || totalSize == null) {
                // Resolve listing & content metadata
                RemSuite__PropertyListing__c listing = [
                    SELECT Name, RemSuite__Property__c, RemSuite__Property__r.Name
                    FROM RemSuite__PropertyListing__c
                    WHERE Id = :listingId
                    LIMIT 1
                ];
                Id propertyId = listing.RemSuite__Property__c;

                ContentVersion cv = [
                    SELECT Id, Title, FileExtension, ContentSize
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

                List<RemSuite__Media__c> mediaList = new List<RemSuite__Media__c>();

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
                
                if (!mediaList.isEmpty()) {
                    RemSuite__Media__c media = mediaList[0];
                    isFloorplan = media.RemSuite__Floorplan__c;
                    isStatement = media.RemSuite__Statement_of_Information__c;
                    isPortal = media.RemSuite__Portal_Available__c;
                }

                contentVersionId = cv.Id;
                totalSize = Integer.valueOf(cv.ContentSize == null ? 0 : cv.ContentSize);

                String ext = String.isBlank(cv.FileExtension) ? 'bin' : cv.FileExtension.toLowerCase();
                String safeTitle = sanitizeForKey(cv.Title);
                String propertyName = sanitizeForKey(listing.RemSuite__Property__r.Name);
                String listingAutoNumber = sanitizeForKey(listing.Name);

                // build blob path similar to your S3 key
                blobName = getFilePath(String.valueOf(propertyId), propertyName, String.valueOf(listingId), listingAutoNumber) + safeTitle + '.' + ext;
            }

            // 2) Small file single PUT (use Put Blob)
            if (totalSize <= CHUNK_BYTES) {
                // Perform single GET from Shepherd then PUT to Azure with x-ms-blob-type: BlockBlob
                Blob body = rangeGetFromShepherd(contentVersionId, null, null); // full body
                if (body == null) {
                    throw new CalloutException('Small-file GET returned empty body.');
                }

                String putUrl = accountBase() + '/' + EncodingUtil.urlEncode(container, 'UTF-8') + '/' + urlKey(blobName) + '?' + SAS_TOKEN;
                HttpRequest putReq = new HttpRequest();
                putReq.setMethod('PUT');
                putReq.setEndpoint(putUrl);
                putReq.setHeader('x-ms-blob-type', 'BlockBlob');
                putReq.setHeader('Content-Type', 'application/octet-stream');
                putReq.setHeader('x-ms-meta-floorplan', String.valueOf(isFloorplan));
                putReq.setHeader('x-ms-meta-statementofinformation', String.valueOf(isStatement));
                putReq.setHeader('x-ms-meta-portalavailable', String.valueOf(isPortal));
                putReq.setBodyAsBlob(body);
                putReq.setTimeout(120000);

                HttpResponse putRes = new Http().send(putReq);
                Integer code = putRes.getStatusCode();
                if (code < 200 || code >= 300) {
                    throw new CalloutException('PUT small object failed: HTTP ' + code + ' | ' + putRes.getBody());
                }

                // success: delete and publish event
                deleteConDoc(contentDocumentId);
                return;
            }

            // 3) Large file: upload blocks
            Integer blocksDoneThisRun = 0;
            while (blocksDoneThisRun < MAX_BLOCKS_THIS_RUN) {
                if (nextStart >= totalSize) break;
                if (DateTime.now().getTime() - T_START > MAX_MS_THIS_RUN) break;

                Integer endChunk = Math.min(nextStart + CHUNK_BYTES, totalSize) - 1;

                // Range GET from Shepherd (with redirect handling)
                Blob chunk = rangeGetFromShepherd(contentVersionId, nextStart, endChunk);
                if (chunk == null || chunk.size() == 0) {
                    throw new CalloutException('Empty chunk for range ' + nextStart + '-' + endChunk);
                }

                Boolean isFinalPart = (nextStart + chunk.size() >= totalSize);
                // Azure allows smaller final block; only non-final blocks should be >= CHUNK_BYTES
                if (!isFinalPart && chunk.size() < CHUNK_BYTES) {
                    throw new CalloutException('Non-final part smaller than chunk size.');
                }

                // Generate block id (fixed-width padded number, base64-encoded)
                // String padded = String.valueOf(blockNumber).padLeft(6, '0'); // "000001"
                String numStr = String.valueOf(blockNumber);
                while (numStr.length() < 6) {
                    numStr = '0' + numStr;
                }
                String padded = numStr; // "000001"
                String blockIdBase64 = EncodingUtil.base64Encode(Blob.valueOf(padded));

                // Upload the block to Azure: PUT ?comp=block&blockid=<base64>
                String blockUploadUrl = accountBase() + '/' + EncodingUtil.urlEncode(container, 'UTF-8') + '/' + urlKey(blobName)
                                        + '?comp=block&blockid=' + EncodingUtil.urlEncode(blockIdBase64, 'UTF-8') + '&' + SAS_TOKEN;

                HttpRequest blockReq = new HttpRequest();
                blockReq.setMethod('PUT');
                blockReq.setEndpoint(blockUploadUrl);
                blockReq.setHeader('Content-Type', 'application/octet-stream');
                blockReq.setBodyAsBlob(chunk);
                blockReq.setTimeout(120000);

                HttpResponse blockRes = new Http().send(blockReq);
                Integer bcode = blockRes.getStatusCode();
                if (bcode < 200 || bcode >= 300) {
                    // aborting: Azure doesn't have explicit abort, but we can throw and stop
                    throw new CalloutException('Upload block #' + blockNumber + ' failed: HTTP ' + bcode + ' | ' + blockRes.getBody());
                }

                // append block id to list
                if (!String.isBlank(blockIdsCsv)) blockIdsCsv += ',';
                blockIdsCsv += blockIdBase64;

                nextStart += chunk.size();
                blockNumber++;
                blocksDoneThisRun++;
            }

            // 4) If we've uploaded all blocks -> commit block list
            if (nextStart >= totalSize) {
                // Build BlockList XML
                String xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>';
                for (String b64 : blockIdsCsv.split(',')) {
                    xml += '<Latest>' + b64 + '</Latest>';
                }
                xml += '</BlockList>';

                String commitUrl = accountBase() + '/' + EncodingUtil.urlEncode(container, 'UTF-8') + '/' + urlKey(blobName)
                                   + '?comp=blocklist&' + SAS_TOKEN;

                HttpRequest commitReq = new HttpRequest();
                commitReq.setMethod('PUT');
                commitReq.setEndpoint(commitUrl);
                commitReq.setHeader('Content-Type', 'application/xml');
                commitReq.setHeader('x-ms-meta-floorplan', String.valueOf(isFloorplan));
                commitReq.setHeader('x-ms-meta-statementofinformation', String.valueOf(isStatement));
                commitReq.setHeader('x-ms-meta-portalavailable', String.valueOf(isPortal));
                commitReq.setBody(xml);
                commitReq.setTimeout(120000);

                HttpResponse commitRes = new Http().send(commitReq);
                Integer ccode = commitRes.getStatusCode();
                if (ccode < 200 || ccode >= 300) {
                    throw new CalloutException('Commit BlockList failed: HTTP ' + ccode + ' | ' + commitRes.getBody());
                }

                // success: delete and event
                deleteConDoc(contentDocumentId);
                return;
            } else {
                // Not finished -> chain another queueable run with preserved state
                System.enqueueJob(new AzureArchiveJob(
                    contentDocumentId, listingId,
                    blobName,
                    nextStart, blockNumber, totalSize,
                    blockIdsCsv, contentVersionId
                ));
            }
        } catch (Exception ex) {
            throw new AuraHandledException('Azure archive failed: ' + ex.getMessage());
        }
    }

    // ====== Helper: Range GET from Shepherd with redirect handling ======
    private Blob rangeGetFromShepherd(Id contentVersionId, Integer startByte, Integer endByte) {
        HttpRequest g = new HttpRequest();
        g.setMethod('GET');

        String base = URL.getOrgDomainUrl().toExternalForm();
        String endpoint = base + '/sfc/servlet.shepherd/version/download/' + contentVersionId;
        g.setEndpoint(endpoint);
        g.setCompressed(false);
        g.setHeader('Accept', 'application/octet-stream');
        g.setHeader('Accept-Encoding', 'identity');
        g.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        if (startByte != null && endByte != null) g.setHeader('Range', 'bytes=' + startByte + '-' + endByte);
        g.setTimeout(120000);

        Http http = new Http();
        HttpResponse gr = http.send(g);
        Integer sc = gr.getStatusCode();

        // handle redirect (documentforce)
        if (sc == 301 || sc == 302 || sc == 307 || sc == 308) {
            String loc = gr.getHeader('Location');
            if (String.isBlank(loc)) throw new CalloutException('Redirect without Location.');
            HttpRequest g2 = new HttpRequest();
            g2.setMethod('GET');
            g2.setEndpoint(loc);
            g2.setCompressed(false);
            g2.setHeader('Accept', 'application/octet-stream');
            g2.setHeader('Accept-Encoding', 'identity');
            g2.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            if (startByte != null && endByte != null) g2.setHeader('Range', 'bytes=' + startByte + '-' + endByte);
            g2.setTimeout(120000);
            gr = http.send(g2);
            sc = gr.getStatusCode();
        }

        // For range requests expect 206, for full expect 200
        if (startByte != null && endByte != null) {
            if (sc != 206) {
                throw new CalloutException('Expected 206 Partial Content but got ' + sc + '. Location=' + gr.getHeader('Location'));
            }
        } else {
            if (sc != 200) {
                throw new CalloutException('Expected 200 OK for full GET but got ' + sc);
            }
        }

        return gr.getBodyAsBlob();
    }

    // ====== Delete ContentDocument & related Media + publish event ======
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

        if (!sr.isSuccess()) {
            System.debug('Failed to publish Refresh_Listing_Page__e event: ' + sr.getErrors()[0].getMessage());
        }
    }

    // ====== Utilities ======
    private static String accountBase() {
        return 'https://' + STORAGE_ACCOUNT + '.blob.core.windows.net';
    }

    private static String urlKey(String key) {
        // URL-encode key but keep '/' as separator
        return EncodingUtil.urlEncode(key, 'UTF-8').replace('+','%20').replace('%2F','/');
    }

    public static String getFilePath(String propertyId, String propertyName, String listingId, String listingAutoNumber) {
        String path = propertyName + '.' + String.valueOf(propertyId) + '/' +
                      listingAutoNumber + '.' + String.valueOf(listingId) + '/';
        return path;
    }

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
