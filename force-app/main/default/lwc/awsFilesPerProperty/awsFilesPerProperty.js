import { LightningElement, api, wire, track } from 'lwc';
import getAwsFilesPerProperty from '@salesforce/apex/getAwsFilesPerProperty.getAwsFilesPerProperty';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { refreshApex } from '@salesforce/apex';

export default class AwsFilesPerProperty extends LightningElement {
    @api recordId;
    @track files = [];
    @track error;

    subscription = {};
    channelName = '/event/Refresh_Listing_Page__e'; 
    wiredFilesResult;

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
            const key = file.Key;
            const fileType = file.Extension.toLowerCase();

            // Set icon based on type
            let iconName = 'doctype:attachment';
            if (['jpg','jpeg','png','gif'].includes(fileType)) iconName = 'doctype:image';
            else if (['pdf'].includes(fileType)) iconName = 'doctype:pdf';
            else if (['doc','docx'].includes(fileType)) iconName = 'doctype:word';
            else if (['xls','xlsx'].includes(fileType)) iconName = 'doctype:excel';
            else if (['ppt','pptx'].includes(fileType)) iconName = 'doctype:ppt';

            // Format file size
            const size = parseInt(file.Size, 10);
            const formattedSize = size < 1024 
                ? size + ' B'
                : size < 1024 * 1024 
                    ? (size / 1024).toFixed(1) + ' KB'
                    : (size / (1024 * 1024)).toFixed(1) + ' MB';

            return {
                Name: file.Name,
                Type: fileType,
                Size: file.Size,
                FormattedSize: formattedSize,
                LastModified: file.LastModified,
                Floorplan: file.IsFloorplan === 'true',
                StatementOfInformation: file.IsStatementOfInformation === 'true',
                PortalAvailable: file.IsPortalAvailable === 'true',
                Key: key,
                iconName: iconName
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
        const messageCallback = () => {
            console.log('Platform Event received, refreshing files...');
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
        const result = await refreshApex(this.wiredFilesResult);
        if (result?.data) {
            this.files = this.mapFiles(result.data);
        }
    }
}
