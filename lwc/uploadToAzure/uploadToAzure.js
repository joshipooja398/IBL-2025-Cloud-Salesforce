import { LightningElement, api, track } from 'lwc';
import archiveAllOnListingAzure from '@salesforce/apex/ArchiveAllFilesController.archiveAllOnListingAzure';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class UploadToAzure extends LightningElement {
    @api recordId;
    @track busy = false;

    get buttonLabel() {
        return this.busy ? 'Archiving...' : 'Archive to Azure';
    }

    async handleArchive() {
        this.busy = true;
        try {
            const res = await archiveAllOnListingAzure({ listingId: this.recordId });

            let msg = '';
            let variant = 'success';
            let title = 'Archive to Azure';

            if (res?.totalFound) {
                msg = `Queued ${res.totalQueued} file(s) for Azure archiving.`;
            } else {
                variant = 'info';
                title = 'No Files';
                msg = res?.message || 'No files found to archive.';
            }

            this.showToast(title, msg, variant);
        } catch (err) {
            console.error('Azure Archive Error', err);
            this.showToast('Archive Failed', err?.body?.message || err.message || 'Unexpected error', 'error');
        } finally {
            this.busy = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant,
            })
        );
    }
}
