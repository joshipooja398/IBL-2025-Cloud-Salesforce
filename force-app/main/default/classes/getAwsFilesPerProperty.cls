public with sharing class getAwsFilesPerProperty {
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getAwsFilesPerProperty(String listingId) {
        List<Map<String, String>> files = new List<Map<String, String>>();
        
       try {
    // Get bucket and folder path
    String bucketName = S3ArchiveJob.bucketFromOrg();

    RemSuite__PropertyListing__c listing = [
        SELECT Id, RemSuite__Property__c, RemSuite__Property__r.Name, Name
        FROM RemSuite__PropertyListing__c
        WHERE Id = :listingId
        LIMIT 1
    ];

    String propertyId = listing.RemSuite__Property__c;
    String propertyName = S3ArchiveJob.sanitizeForKey(listing.RemSuite__Property__r.Name);
    String listingName = listing.Name;
    String folderPath = S3ArchiveJob.getFilePath(propertyId, propertyName, listingId, listingName);

    // List objects in S3
    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:AWS_S3_Service/' + bucketName 
                    + '?list-type=2&prefix=' + EncodingUtil.urlEncode(folderPath, 'UTF-8'));
    req.setMethod('GET'); // must be GET to get XML body
    req.setHeader('Content-Type', 'application/xml');

    Http http = new Http();
    HttpResponse res = http.send(req);

    if (res.getStatusCode() != 200) {
        throw new AuraHandledException('Failed to list files. Status: ' + res.getStatus());
    }

    Dom.Document doc = new Dom.Document();
    doc.load(res.getBody());
    Dom.XMLNode root = doc.getRootElement();

    // Iterate <Contents> nodes
    for (Dom.XMLNode contentNode : root.getChildElements()) {
        if (!contentNode.getName().endsWith('Contents')) continue;

        String key = '';
        String size = '';
        String lastModified = '';

        for (Dom.XMLNode child : contentNode.getChildElements()) {
            if (child.getName().endsWith('Key')) key = child.getText();
            if (child.getName().endsWith('Size')) size = child.getText();
            if (child.getName().endsWith('LastModified')) lastModified = child.getText();
        }

        if (String.isBlank(key)) continue;

        // HEAD request to fetch user-defined metadata
        HttpRequest req1 = new HttpRequest();
        req1.setMethod('HEAD');
        req1.setEndpoint('callout:AWS_S3_Service/' + bucketName + '/' + EncodingUtil.urlEncode(key, 'UTF-8'));

        HttpResponse res1 = http.send(req1);

        // Build file info map
        Map<String, String> fileInfo = new Map<String, String>();
        fileInfo.put('Key', key);
        fileInfo.put('Size', size);
        fileInfo.put('LastModified', lastModified);

        // File name & extension
        Integer dotIndex = key.lastIndexOf('.');
        String fileNameWithPrefix = (dotIndex > 0) ? key.substring(key.lastIndexOf('/') + 1, dotIndex)
                                           : key.substring(key.lastIndexOf('/') + 1);
        String extension = (dotIndex > 0) ? key.substring(dotIndex + 1) : '';

        // Known prefixes
        List<String> prefixes = new List<String>{'floorplan_', 'statement_of_information_', 'portal_available_'};
        
        // Initialize flags
        Boolean isFloorplan = false;
        Boolean isSOI = false;
        Boolean isPortal = false;

        // Remove all prefixes that match
        String actualName = fileNameWithPrefix;
        for (String prefix : prefixes) {
            if (actualName.startsWith(prefix)) {
                if (prefix == 'floorplan_') isFloorplan = true;
                if (prefix == 'statement_of_information_') isSOI = true;
                if (prefix == 'portal_available_') isPortal = true;
                actualName = actualName.replaceFirst(prefix, ''); // remove prefix
            }
        }

        // Add to fileInfo map
        fileInfo.put('Name', actualName);
        fileInfo.put('Extension', extension);
        fileInfo.put('IsFloorplan', String.valueOf(isFloorplan));
        fileInfo.put('IsStatementOfInformation', String.valueOf(isSOI));
        fileInfo.put('IsPortalAvailable', String.valueOf(isPortal));
        
        files.add(fileInfo);
    }

} catch (Exception e) {
    throw new AuraHandledException('Error fetching S3 files: ' + e.getMessage());
}
        return files;
    }
}


