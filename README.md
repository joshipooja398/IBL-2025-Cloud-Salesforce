# IBL-2025-Cloud-Salesforce
It is my internship demo which has Integration of Salesforce with Cloud.

# Cloud File Archiving Flows
This project manages file uploads and archiving between Salesforce and two cloud storage platforms - Microsoft Azure and Amazon AWS.
Each integration flow uses a dedicated Lightning Web Component (LWC) and Apex classes to handle file retrieval, batching, and uploading.

## Azure Flow
Component: AzureFilesWithUpload

Overview - This LWC displays all files stored in Azure Blob Storage and provides an option to upload new files to Azure.

Flow:
    1.The user clicks the "Upload Files to Azure" button.
    2.This triggers the Apex class ArchiveAllFilesController.
    3.The controller gathers all media files related to the given listingId.
    4.It then calls ArchiveBatchLauncherAzure, which initializes a batch job.
    5.The batch job passes data to AzureArchiveJob with a scope size of 1.
    6.AzureArchiveJob handles the actual upload of files to Azure Blob Storage.

## AWS Flow
Component: AwsFilesWithUpload

Overview - This LWC displays all files stored in AWS S3 and allows users to upload new files to AWS.

Flow:
    1.The user clicks the "Upload Files to AWS" button.
    2.This triggers the Apex class ArchiveAllFilesController.
    3.The controller gathers all media files for the specified listingId.
    4.It then calls ArchiveBatchLauncher, which starts a batch process.
    5.The batch process passes data to S3ArchiveJob with a scope size of 1.
    6.S3ArchiveJob manages the upload of files to AWS S3.
