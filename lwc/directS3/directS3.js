import { LightningElement, api, track } from 'lwc';
import getAllPresignedUrls from '@salesforce/apex/S3FileController.getAllPresignedUrls';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class DirectS3 extends LightningElement {
    @api recordId; // PropertyListingId
    @track uploadedFiles = [];

    // Handle button click
    async handleUploadAll() {
        if(!this.recordId){
            this.showToast('Error','recordId is missing','error');
            return;
        }

        this.uploadedFiles = [];

        try {
            // Step 1: Get all presigned URLs from Apex
            const files = await getAllPresignedUrls({ propertyListingId: this.recordId });

            // Step 2: Upload each file directly to S3
            for(let i=0; i<files.length; i++){
                const f = files[i];

                if(f.status !== 'Ready'){
                    this.uploadedFiles.push(f);
                    continue;
                }

                try {
                    const uploadResponse = await fetch(f.uploadUrl, {
                        method: 'PUT',
                        headers: { 'Content-Type': f.fileName.split('.').pop() }, // optional: real content-type
                        body: null // since we cannot pass VersionData here from Apex, you need to modify Apex to include Base64 content if you want full automation
                    });

                    f.status = uploadResponse.ok ? 'Uploaded' : 'Failed';
                    f.message = uploadResponse.ok ? 'Upload successful' : uploadResponse.statusText;

                } catch(e){
                    f.status = 'Error';
                    f.message = e.message;
                }

                this.uploadedFiles.push(f);
            }
            const successCount = this.uploadedFiles.filter(f => f.status === 'Uploaded').length;
            this.showToast('Upload Finished', `${successCount} of ${files.length} files uploaded successfully!`, 'success');

        } catch(error){
            console.error('Error fetching presigned URLs:', error);
            this.showToast('Error','Failed to get files for upload','error');
        }
    }

    showToast(title, message, variant){
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
