public with sharing class S3FileController {
    private static final String NAMED_CREDENTIAL = 'AWS_Presigned_Service';

    @AuraEnabled
    public static List<Map<String, Object>> getAllPresignedUrls(Id propertyListingId) {
        List<Map<String, Object>> uploadFilesList = new List<Map<String, Object>>();

        // Step 1: Query PropertyId from PropertyListing
        RemSuite__PropertyListing__c listing = [
            SELECT Id, RemSuite__Property__c
            FROM RemSuite__PropertyListing__c
            WHERE Id = :propertyListingId
            LIMIT 1
        ];

        
        if(listing == null || listing.RemSuite__Property__c == null){
            throw new AuraHandledException('Property not found for the given listing.');
        }
        
        String propertyId = listing.RemSuite__Property__c;
        String folderName = listing.Id;

        // Step 2: Get all ContentDocuments linked to the listing
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId 
            FROM ContentDocumentLink 
            WHERE LinkedEntityId = :propertyListingId
        ];

        if(links.isEmpty()){
            return new List<Map<String, Object>>{
                new Map<String, Object>{ 'status' => 'No Files Found' }
            };
        }

        Set<Id> docIds = new Set<Id>();
        for(ContentDocumentLink l : links){
            docIds.add(l.ContentDocumentId);
        }

        List<ContentVersion> versions = [
            SELECT Id, Title, FileExtension, VersionData 
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds
            AND IsLatest = TRUE
        ];

        Http http = new Http();

        // Step 3: Generate presigned URL for each file via Lambda
        for(ContentVersion cv : versions){
            Map<String, Object> fileInfo = new Map<String, Object>();
            fileInfo.put('fileName', cv.Title + '.' + cv.FileExtension);

            try {
                Map<String, Object> payload = new Map<String, Object>{
                    'bucketName' => propertyId,
                    'propertyListingId' => folderName,
                    'fileName'   => cv.Title + '.' + cv.FileExtension,
                    'contentType'=> contentType(cv.FileExtension)
                };

                HttpRequest req = new HttpRequest();
                req.setEndpoint('callout:' + NAMED_CREDENTIAL + '/generate-presigned-url');
                req.setMethod('POST');
                req.setHeader('Content-Type','application/json');
                req.setBody(JSON.serialize(payload));

                HttpResponse res = http.send(req);

                if(res.getStatusCode() == 200){

                    Map<String,Object> result = (Map<String,Object>) JSON.deserializeUntyped(res.getBody());
                    fileInfo.put('uploadUrl', result.get('uploadUrl'));
                    fileInfo.put('bucketName', result.get('bucketName'));
                    fileInfo.put('objectKey', result.get('key'));
                    fileInfo.put('status', 'Ready');
                } else {
                    fileInfo.put('status', 'Failed');
                    fileInfo.put('message', res.getBody());
                }

            } catch(Exception e){
                fileInfo.put('status', 'Error');
                fileInfo.put('message', e.getMessage());
            }

            uploadFilesList.add(fileInfo);
        }

        return uploadFilesList;
    }

    // Helper: Convert file extension → Content-Type
    private static String contentType(String ext){
        if(ext == null) return 'application/octet-stream';
        String f = ext.toLowerCase();
        if(f=='png') return 'image/png';
        if(f=='jpg') return 'image/jpg';
        if(f=='jpeg') return 'image/jpeg';
        if(f=='pdf') return 'application/pdf';
        if(f=='docx') return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
        if(f=='xlsx') return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
        if(f=='txt') return 'text/plain';
        return 'application/octet-stream';
    }
}
