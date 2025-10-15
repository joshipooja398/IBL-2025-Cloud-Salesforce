import { LightningElement, api, track, wire } from 'lwc';
import getAwsFilesPerProperty from '@salesforce/apex/getAwsFilesPerProperty.getAwsFilesPerProperty';
import archiveAllOnListingAWS from '@salesforce/apex/ArchiveAllFilesController.archiveAllOnListingAWS';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { refreshApex } from '@salesforce/apex';

export default class AwsFilesWithUpload extends LightningElement {
    @api recordId;
    @track files = [];
    @track error;
    @track wiredFilesResult;
    @track busy = false;
    subscription = {};

    channelName = '/event/Refresh_Listing_Page__e';

    get buttonLabel() {
        return this.busy ? 'Archiving...' : 'Archive to S3';
    }

    get hasFiles() {
        return this.files && this.files.length > 0;
    }

    @wire(getAwsFilesPerProperty, { listingId: '$recordId' })
    wiredFiles(result) {
        this.wiredFilesResult = result;
        const { data, error } = result;
        if (data) {
            this.files = this.mapFiles(data);
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.files = [];
        }
    }

    mapFiles(data) {
        return data.map(file => {
            const ext = file.Extension ? file.Extension.toLowerCase() : '';
            let iconName = 'doctype:attachment';
            if (['jpg','jpeg','png','gif'].includes(ext)) iconName = 'doctype:image';
            else if (ext === 'pdf') iconName = 'doctype:pdf';
            else if (['doc','docx'].includes(ext)) iconName = 'doctype:word';
            else if (['xls','xlsx'].includes(ext)) iconName = 'doctype:excel';
            else if (['ppt','pptx'].includes(ext)) iconName = 'doctype:ppt';
            else if (['mp4','mov','avi','mkv'].includes(ext)) iconName = 'doctype:video';

            const size = parseInt(file.Size, 10);
            const formattedSize = size < 1024
                ? size + ' B'
                : size < 1024 * 1024
                    ? (size / 1024).toFixed(1) + ' KB'
                    : (size / (1024 * 1024)).toFixed(1) + ' MB';

            return {
                ...file,
                iconName,
                FormattedSize: formattedSize,
                Floorplan: file.IsFloorplan === 'true',
                StatementOfInformation: file.IsStatementOfInformation === 'true',
                PortalAvailable: file.IsPortalAvailable === 'true'
            };
        });
    }

    connectedCallback() {
        this.handleSubscribe();
        this.registerErrorListener();
    }

    disconnectedCallback() {
        this.handleUnsubscribe();
    }

    handleSubscribe() {
        const messageCallback = () => this.refreshFiles();
        subscribe(this.channelName, -1, messageCallback).then(response => this.subscription = response);
    }

    handleUnsubscribe() {
        unsubscribe(this.subscription, () => {});
    }

    registerErrorListener() {
        onError(error => console.error('EMP API error: ', JSON.stringify(error)));
    }

    async refreshFiles() {
        await refreshApex(this.wiredFilesResult);
    }

    // Archive button handler
    async handleArchive() {
        this.busy = true;
        try {
            const res = await archiveAllOnListingAWS({ listingId: this.recordId });

            let msg = '';
            let variant = 'success';
            let title = 'Archive to S3';

            if (res?.totalFound) {
                msg = `Queued ${res.totalQueued} file(s) for S3 archiving.`;
            } else {
                variant = 'info';
                title = 'No Files';
                msg = res?.message || 'No files found on this listing.';
            }

            this.showToast(title, msg, variant);
        } catch (err) {
            this.showToast('Archive Failed', err?.body?.message || err.message || 'Unexpected error', 'error');
        } finally {
            this.busy = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
