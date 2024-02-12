# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# This file contains the code for the Lambda function that handles custom
# cloudformation resource management for Organization policies

import json # parsing json
import logging # log output for Lambda
import boto3 # aws stuff
import time # sleep function
import uuid # generate unique ID for SQS message
import zipfile # managing zipped data in S3
from io import BytesIO # used for file buffer to get info from file in S3
from os import getenv # environment variables

sqs_queue_url = getenv("SQS_QUEUE_URL") # URL of the FIFO queue used to process updates
retry_count = getenv("RETRY_COUNT", 3) # global count for retries during processing errors

# instantiate a logging tool
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# create aws clients
s3_resource = boto3.resource('s3')
lambda_client = boto3.client('lambda')
sqs_client = boto3.client('sqs')

#################################################
# Helper function to unzip files uploaded to S3
#################################################
def unzip_files(s3_bucket, s3_key):

    # set retry flag for re-processing purposes
    retries = 0

    # set initial file value to None so that it can be used as completion criteria for loop when it is no longer 'None'
    zipped_file = None

    # iterate until we max out; iterator set to value above max if processing is successful before max retries
    while zipped_file is None and retries < retry_count:
        try: 
            # get the zip file from the S3 location
            zipped_file = s3_resource.Object(bucket_name=s3_bucket, key=s3_key)

            # read the file info if we get the object
            if zipped_file is not None:
                # if the file exists, create a buffer to get the data
                buffer = BytesIO(zipped_file.get()['Body'].read())
                retries = retry_count + 1
        
        # if processing did not complete, try again but log an error
        except Exception as e:
            retries += 1
            logger.error(f"Error occurred retrieving .zip file from S3. Exception is: {e}")  
    
    # start working with the .zip file
    with zipfile.ZipFile(buffer) as zipf:

        # flag to see if we got everything successfully re-inflated
        process_completed = False

        # go through all the files in the archive
        for file in zipf.namelist():

            # derive the folder name from the .zip to put the files in
            new_key = s3_key.replace(".zip","/") + f"{file}"

            # upload the unzipped file back to S3
            try:
                s3_resource.meta.client.upload_fileobj(zipf.open(file),Bucket=s3_bucket,Key=new_key)
            except Exception as e:
                logger.error(f"Encountered an issue with upload of the object to {new_key}. Exception is: {e}")
            
            # be sure that the object exists; if they all do after processing is done, we can delete the .zip
            try:
                if s3_resource.Object(s3_bucket,new_key).get()['ResponseMetadata']['HTTPStatusCode'] is not None:
                    # sets to true; gets re-evaluated until everything is done
                    process_completed = True

            except Exception as e:
                logger.error(f"Something went wrong with unzipping files. Exception is: {e}")
                process_completed = False

        # delete the .zip archive if we successfully unzipped everything        
        if process_completed == True:
            # delete and set the flag that we are done processing
            try:
                response = s3_resource.Object(s3_bucket, s3_key).delete()
                # if the operation succeeded, set the iterator above its max to end processing
                if response['ResponseMetadata']['HTTPStatusCode'] == 200:
                    process_completed = True
            # if the processing did not complete, flag it as failed
            except Exception as e:
                logger.error(f"Encountered an error deleting the original .zip file. Exception is {e}")
                process_completed = False
    
    # return the value (true or false) to make sure processing happened fully
    return(process_completed)

# end function unzip_files

##################################################
# Main Lambda handler function. Event trigger
# should come from an object upload or deletion
# in a specific S3 bucket. The file should be a
# .zip archive, which is unzipped and then
# deleted. Once this is complete, the relevant
# information is sent to a SQS queue to be
# processed by a parent Lambda function.
##################################################
def lambda_handler(event, context):

    # log beginning of the handler event
    logger.info('event received: {}'.format(event))
    
    # boolean to flag our progress
    process_completed = False

    # create a variable from the globalized value
    global retry_count

    # fix string values from CloudFormation
    retry_count = int(retry_count)

    # get the relevant info into variables
    s3_bucket = event['Records'][0]['s3']['bucket']['name']
    s3_key = event['Records'][0]['s3']['object']['key']

    try:
        # see if there is an upload
        if "ObjectCreated" in event['Records'][0]['eventName'] and ".zip" in s3_key:
            # request the unzip and get the feedback if it was successful
            process_completed = unzip_files(s3_bucket, event['Records'][0]['s3']['object']['key'])
            # log end of unzip phase
            logger.info(f"Processing run finished. The process completion boolean is: {process_completed}")
            
            # if we finished everything, pass it to the SQS queue
            if process_completed == True:
                # derive the backup policy name from the uploaded folder
                policy_name = s3_key.replace(".zip","")
                logger.info(f"S3 Object {s3_key} uploaded to {s3_bucket}. Sending event to {sqs_queue_url}")

                # construct the message to send to SQS
                response = sqs_client.send_message(
                    QueueUrl = sqs_queue_url,
                    MessageAttributes={
                        'Bucket': {
                            'DataType': 'String',
                            'StringValue': s3_bucket
                        },
                        'UpdatedObject': {
                            'DataType': 'String',
                            'StringValue': policy_name
                        },
                        'Action': {
                            'DataType': 'String',
                            'StringValue': 'Upload'
                        }
                    },
                    # generate a unique message ID so that multiple file changes for the same policy don't get incorrectly deduplicated
                    MessageGroupId=str(uuid.uuid4()),
                    MessageBody=(
                        f'S3 Object {policy_name} uploaded to {s3_bucket}'
                    )
                )
              
        # see if there is an object deletion
        elif "ObjectRemoved" in event['Records'][0]['eventName'] and ".zip" not in s3_key:
            logger.info(f"S3 Object {s3_key} deleted from {s3_bucket}. Sending event to {sqs_queue_url}")

            # construct the message to send to SQS
            response = sqs_client.send_message(
                QueueUrl = sqs_queue_url,
                MessageAttributes={
                    'Bucket': {
                        'DataType': 'String',
                        'StringValue': s3_bucket
                    },
                    'UpdatedObject': {
                        'DataType': 'String',
                        'StringValue': s3_key
                    },
                    'Action': {
                        'DataType': 'String',
                        'StringValue': 'Delete'
                    }
                },
                # generate a unique message ID so that multiple file changes for the same policy don't get incorrectly deduplicated
                MessageGroupId=str(uuid.uuid4()),
                MessageBody=(
                    f'S3 Object {s3_key} deleted from {s3_bucket}'
                )
            )

    # if all else failed, log the exception
    except Exception as e:
        logger.error(f"Failure occurred. Event info is: {e}.")
        raise

# end of function lambda_handler
