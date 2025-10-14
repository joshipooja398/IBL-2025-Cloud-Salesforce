import { LightningElement, api } from 'lwc';
import archiveAllOnListingAWS from '@salesforce/apex/ArchiveAllFilesController.archiveAllOnListingAWS';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class ArchiveAllFilesButton extends LightningElement {

  @api recordId; // RemSuite__PropertyListing__c Id
  @api label = 'Archive All Files to S3';
  busy = false;

  async archiveAll() {
    this.busy = true;
    try {
      const res = await archiveAllOnListingAWS({ listingId: this.recordId });

      let variant = 'success';
      let title = 'Archive to S3';
      let msg = res?.message || '';

      if (!res?.totalFound) {
        variant = 'info';
        title = 'No Files';
        msg = res?.message || 'No files found on this listing.';
      }

      this.dispatchEvent(
        new ShowToastEvent({
          title,
          message: msg,
          variant,
        })
      );
    } catch (e) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Archive failed',
          message: e?.body?.message || e.message || 'Unexpected error',
          variant: 'error',
          mode: 'sticky',
        })
      );
    } finally {
      this.busy = false;
    }
  }
}