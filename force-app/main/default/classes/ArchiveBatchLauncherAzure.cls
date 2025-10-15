public class ArchiveBatchLauncherAzure implements Database.Batchable<Id> {
    private final List<Id> docIds;   // ContentDocumentIds
    private final Id listingId;      // RemSuite__PropertyListing__c Id

    public ArchiveBatchLauncherAzure(List<Id> docIds, Id listingId) {
        this.docIds   = (docIds == null) ? new List<Id>() : new List<Id>(docIds);
        this.listingId = listingId;
    }

    public Iterable<Id> start(Database.BatchableContext bc) {
        return docIds;
    }

    public void execute(Database.BatchableContext bc, List<Id> scope) {
        // scope size will be 1 (see executeBatch call)
        System.enqueueJob(new AzureArchiveJob(scope[0], listingId));
    }

    public void finish(Database.BatchableContext bc) {
        // Optional finish logic
    }
}
