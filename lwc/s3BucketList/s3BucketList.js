import { LightningElement, wire, track } from 'lwc';
import getBucketList from '@salesforce/apex/S3Controller.getBucketList';

export default class S3BucketList extends LightningElement {
    @track buckets;
    @track error;

    @wire(getBucketList)
    wiredBuckets({ data, error }) {
        if (data) {
            this.buckets = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body ? error.body.message : error.message;
            this.buckets = undefined;
        }
    }
}
