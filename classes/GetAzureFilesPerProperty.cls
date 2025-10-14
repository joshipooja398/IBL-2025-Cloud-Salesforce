public with sharing class GetAzureFilesPerProperty {
    private static final String STORAGE_ACCOUNT = 'remsuitetest';
    private static final String CONTAINER_NAME = 'remsuite-client-container';
    private static final String SAS_TOKEN = 'sp=racwdl&st=2025-09-15T01:25:53Z&se=2025-11-01T08:40:53Z&spr=https&sv=2024-11-04&sr=c&sig=e16qgGt%2Fghc7b3Hxa0OUNbFIul4XqbM1TTqc06E0hWY%3D'; // no leading "?"

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getAzureFilesPerProperty(Id listingId) {
        List<Map<String, String>> files = new List<Map<String, String>>();

        try {
            // 1. Get property & listing info
            RemSuite__PropertyListing__c listing = [
                SELECT Id, RemSuite__Property__c, RemSuite__Property__r.Name, Name
                FROM RemSuite__PropertyListing__c
                WHERE Id = :listingId
                LIMIT 1
            ];

            String propertyId = listing.RemSuite__Property__c;
            String propertyName = AzureArchiveJob.sanitizeForKey(listing.RemSuite__Property__r.Name);
            String listingName = listing.Name;

            // 2. Generate folder path
            String folderPath = AzureArchiveJob.getFilePath(propertyId, propertyName, listingId, listingName);

            // 3. Call Azure with prefix (only this folderPath)
            String endpoint = 'https://' + STORAGE_ACCOUNT + 
                              '.blob.core.windows.net/' + 
                              CONTAINER_NAME + 
                              '?restype=container&comp=list&include=metadata' +  // ✅ include metadata
                              '&prefix=' + EncodingUtil.urlEncode(folderPath, 'UTF-8') + 
                              '&' + SAS_TOKEN;

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                throw new AuraHandledException('Failed to list Azure files. Status: ' + res.getStatus());
            }

            Dom.Document doc = res.getBodyDocument();
            Dom.XMLNode root = doc.getRootElement();

            for (Dom.XMLNode blobNode : root.getChildElement('Blobs', null).getChildElements()) {
                String blobName = blobNode.getChildElement('Name', null).getText();

                // Clean filename (remove folder path prefix)
                String cleanName = blobName.replace(folderPath, '');

                // Skip if it's just the folder path (empty filename)
                if (String.isBlank(cleanName)) continue;

                // Extract metadata
                Long sizeBytes = 0;
                String lastModified = '';
                String floorplan = '';
                String statementOfInfo = '';
                String portalAvailable = '';

                for (Dom.XMLNode child : blobNode.getChildElements()) {
                    if (child.getName().equalsIgnoreCase('Properties')) {
                        for (Dom.XMLNode prop : child.getChildElements()) {
                            if (prop.getName().equalsIgnoreCase('Content-Length')) {
                                sizeBytes = Long.valueOf(prop.getText());
                            }
                            if (prop.getName().equalsIgnoreCase('Last-Modified')) {
                                lastModified = prop.getText();
                            }
                        }
                    }
                    if (child.getName().equalsIgnoreCase('Metadata')) {
                        for (Dom.XMLNode meta : child.getChildElements()) {
                            if (meta.getName().equalsIgnoreCase('floorplan')) {
                                floorplan = meta.getText();
                            }
                            if (meta.getName().equalsIgnoreCase('statementofinformation')) {
                                statementOfInfo = meta.getText();
                            }
                            if (meta.getName().equalsIgnoreCase('portalavailable')) {
                                portalAvailable = meta.getText();
                            }
                        }
                    }
                }

                // Convert size into human readable (KB / MB)
                String formattedSize;
                if (sizeBytes < 1024) {
                    formattedSize = sizeBytes + ' B';
                } else if (sizeBytes < 1024 * 1024) {
                    formattedSize = String.valueOf((sizeBytes / 1024.0)).substring(0,4) + ' KB';
                } else {
                    formattedSize = String.valueOf((sizeBytes / 1048576.0)).substring(0,4) + ' MB';
                }

                // Extract extension/type
                Integer dotIndex = cleanName.lastIndexOf('.');
                String nameOnly = (dotIndex > 0) ? cleanName.substring(0, dotIndex) : cleanName;
                String extension = (dotIndex > 0) ? cleanName.substring(dotIndex + 1).toLowerCase() : '';

                // Build URL for direct access
                String url = 'https://' + STORAGE_ACCOUNT + 
                             '.blob.core.windows.net/' + 
                             CONTAINER_NAME + '/' + 
                             EncodingUtil.urlEncode(blobName, 'UTF-8') + 
                             '?' + SAS_TOKEN;

                // Build map
                Map<String, String> fileInfo = new Map<String, String>();
                fileInfo.put('Name', nameOnly);
                fileInfo.put('Extension', extension);
                fileInfo.put('Size', formattedSize);
                fileInfo.put('LastModified', lastModified);
                fileInfo.put('Url', url);
                fileInfo.put('Floorplan', floorplan);
                fileInfo.put('StatementOfInformation', statementOfInfo);
                fileInfo.put('PortalAvailable', portalAvailable);

                files.add(fileInfo);
            }

        } catch (Exception e) {
            throw new AuraHandledException('Error fetching Azure files: ' + e.getMessage());
        }
        return files;
    }
}
