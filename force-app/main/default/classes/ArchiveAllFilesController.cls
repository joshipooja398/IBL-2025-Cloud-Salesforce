public class ArchiveAllFilesController {
    public class Result {
        @AuraEnabled public Integer totalFound;
        @AuraEnabled public Integer totalQueued;
        @AuraEnabled public String message;
    }

    @AuraEnabled(cacheable=false)
    public static Result archiveAllOnListingAWS(Id listingId) {
        if (listingId == null) throw new AuraHandledException('Missing record id');

        Result r = new Result();

        // Get all related media records
        Set<Id> mediaIds = new Set<Id>();
        List<RemSuite__Media__c> mediaList = [
            SELECT Id, Name 
            FROM RemSuite__Media__c 
            WHERE RemSuite__Property_Listing__c = :listingId
        ];
        for (RemSuite__Media__c m : mediaList) {
            mediaIds.add(m.Id);
        }

        if (mediaIds.isEmpty()) {
            r.totalFound = 0;
            r.totalQueued = 0;
            r.message = 'No media found on this listing.';
            return r;
        }

        // Collect ContentDocumentIds
        List<Id> docIds = new List<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :mediaIds
        ]) {
            if (l.ContentDocumentId != null) docIds.add(l.ContentDocumentId);
        }

        if (docIds.isEmpty()) {
            r.totalFound = 0;
            r.totalQueued = 0;
            r.message = 'No files found on this listing.';
            return r;
        }

        // Launch archive batch
        Database.executeBatch(new ArchiveBatchLauncher(docIds, listingId), 1);

        r.totalFound = docIds.size();
        r.totalQueued = docIds.size();
        r.message = r.totalFound + ' files queued for archive.';
        return r;
    }

    @AuraEnabled(cacheable=false)
    public static Result archiveAllOnListingAzure(Id listingId) {
        if (listingId == null) throw new AuraHandledException('Missing record id');

        Result r = new Result();

        // Get all related media records
        Set<Id> mediaIds = new Set<Id>();
        List<RemSuite__Media__c> mediaList = [
            SELECT Id, Name 
            FROM RemSuite__Media__c 
            WHERE RemSuite__Property_Listing__c = :listingId
        ];
        for (RemSuite__Media__c m : mediaList) {
            mediaIds.add(m.Id);
        }

        if (mediaIds.isEmpty()) {
            r.totalFound = 0;
            r.totalQueued = 0;
            r.message = 'No media found on this listing.';
            return r;
        }

        // Collect ContentDocumentIds
        List<Id> docIds = new List<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :mediaIds
        ]) {
            if (l.ContentDocumentId != null) docIds.add(l.ContentDocumentId);
        }

        if (docIds.isEmpty()) {
            r.totalFound = 0;
            r.totalQueued = 0;
            r.message = 'No files found on this listing.';
            return r;
        }

        // Launch archive batch for Azure
        Database.executeBatch(new ArchiveBatchLauncherAzure(docIds, listingId), 1);

        r.totalFound = docIds.size();
        r.totalQueued = docIds.size();
        r.message = r.totalFound + ' files queued for Azure archive.';
        return r;
    }
}
