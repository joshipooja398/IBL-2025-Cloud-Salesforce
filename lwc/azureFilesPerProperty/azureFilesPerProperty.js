import { LightningElement, api, wire, track } from 'lwc';
import getAzureFilesPerProperty from '@salesforce/apex/GetAzureFilesPerProperty.getAzureFilesPerProperty';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { refreshApex } from '@salesforce/apex';

export default class AzureFilesPerProperty extends LightningElement {
    @api recordId;
    @track files;
    @track error;
    @track wiredFilesResult
    subscription = {};
    channelName = '/event/Refresh_Listing_Page__e'; // your Platform Event API name
    columns = [
        { label: 'File Name', fieldName: 'Name', type: 'text' },
        { label: 'Type', fieldName: 'Extension', type: 'text' },
        { label: 'Size', fieldName: 'Size', type: 'text' }, 
        { label: 'Floorplan', fieldName: 'Floorplan', type: 'boolean' },
        { label: 'Statement of Info', fieldName: 'StatementOfInformation', type: 'boolean' },
        { label: 'Portal Available', fieldName: 'PortalAvailable', type: 'boolean' },
    ];

    @wire(getAzureFilesPerProperty, { listingId: '$recordId' })
    wiredFiles(result) {
        this.wiredFilesResult = result;
        if (result.data) {
            // Convert string metadata to boolean and add file icon
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
            console.log('Platform AZURE Event received, refreshing files...');
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

    // Refresh the wire and remap files
    async refreshFiles() {
        await refreshApex(this.wiredFilesResult);
    }
}
