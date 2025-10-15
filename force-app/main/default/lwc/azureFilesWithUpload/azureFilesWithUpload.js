import { LightningElement, api, wire, track } from 'lwc';
import getAzureFilesPerProperty from '@salesforce/apex/GetAzureFilesPerProperty.getAzureFilesPerProperty';
import archiveAllOnListingAzure from '@salesforce/apex/ArchiveAllFilesController.archiveAllOnListingAzure';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { refreshApex } from '@salesforce/apex';

export default class AzureFilesWithUpload extends LightningElement {
    @api recordId;
    @track files;
    @track error;
    @track wiredFilesResult;
    @track busy = false;
    subscription = {};

    channelName = '/event/Refresh_Listing_Page__e';

    columns = [
        { label: 'File Name', fieldName: 'Name', type: 'text' },
        { label: 'Type', fieldName: 'Extension', type: 'text' },
        { label: 'Size', fieldName: 'Size', type: 'text' }, 
        { label: 'Floorplan', fieldName: 'Floorplan', type: 'boolean' },
        { label: 'Statement of Info', fieldName: 'StatementOfInformation', type: 'boolean' },
        { label: 'Portal Available', fieldName: 'PortalAvailable', type: 'boolean' },
    ];

    get buttonLabel() {
        return this.busy ? 'Archiving...' : 'Archive All Files to Azure';
    }

    get hasFiles() {
        return this.files && this.files.length > 0;
    }

    @wire(getAzureFilesPerProperty, { listingId: '$recordId' })
    wiredFiles(result) {
        this.wiredFilesResult = result;
        if (result.data) {
            this.files = result.data.map(file => {
                let icon = 'doctype:unknown';
                const ext = file.Extension ? file.Extension.toLowerCase() : '';

                if (['jpg', 'jpeg', 'png', 'gif'].includes(ext)) icon = 'doctype:image';
                else if (ext === 'pdf') icon = 'doctype:pdf';
                else if (['doc', 'docx'].includes(ext)) icon = 'doctype:word';
                else if (['xls', 'xlsx'].includes(ext)) icon = 'doctype:excel';
                else if (['ppt', 'pptx'].includes(ext)) icon = 'doctype:ppt';
                else if (['mp4', 'mov', 'avi', 'mkv'].includes(ext)) icon = 'doctype:video';

                return {
                    ...file,
                    Floorplan: file.Floorplan === 'true',
                    StatementOfInformation: file.StatementOfInformation === 'true',
                    PortalAvailable: file.PortalAvailable === 'true',
                    iconName: icon
                };
            });
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body ? result.error.body.message : result.error.message;
            this.files = undefined;
        }
    }

    connectedCallback() {
        this.handleSubscribe();
        this.registerErrorListener();
    }

    disconnectedCallback() {
        this.handleUnsubscribe();
    }

    handleSubscribe() {
        const messageCallback = () => {
            this.refreshFiles();
        };
        subscribe(this.channelName, -1, messageCallback).then(response => {
            this.subscription = response;
        });
    }

    handleUnsubscribe() {
        unsubscribe(this.subscription, () => {});
    }

    registerErrorListener() {
        onError(error => {
            console.error('EMP API error: ', JSON.stringify(error));
        });
    }

    async refreshFiles() {
        await refreshApex(this.wiredFilesResult);
    }

    // Archive button handler
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
