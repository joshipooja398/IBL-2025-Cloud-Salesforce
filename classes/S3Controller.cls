public with sharing class S3Controller {
    @AuraEnabled(cacheable=true)
    public static List<String> getBucketList() {
        List<String> bucketNames = new List<String>();
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:AWS_S3_Service/'); // Named Credential
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/xml');
            
            Http http = new Http();
            HTTPResponse res = http.send(req);

            if (res.getStatusCode() == 200) {
                Dom.Document doc = new Dom.Document();
                doc.load(res.getBody());
                Dom.XMLNode root = doc.getRootElement();

                // Get the second child of the root (index 1 because index starts at 0)
                List<Dom.XMLNode> rootChildren = root.getChildElements();
                if (rootChildren.size() > 1) {
                    Dom.XMLNode bucketsNode = rootChildren[1]; // This should be <Buckets>

                    for (Dom.XMLNode bucketNode : bucketsNode.getChildElements()) {
                        Dom.XMLNode nameNode = bucketNode.getChildElements()[0]; // First child inside <Bucket>
                        bucketNames.add(nameNode.getText());
                    }
                }
            } else {
                throw new AuraHandledException('Failed to retrieve bucket list. Status: ' + res.getStatus());
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error: ' + e.getMessage());
        }
        return bucketNames;
    }
}