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
# Organization Backup Policy management

import json # parsing json files
import logging # log stuff
import boto3 # aws stuff
import re # regex parsing
import time # sleep function
from os import getenv # environment variables

policy_definition_file_name = getenv("POLICY_DEFINITION_FILE_NAME", "policy_definition.json") # name of the Backup Policy .json definition
target_list_file_name = getenv("TARGET_LIST_FILE_NAME", "target_list.json") # name of the .json listing of target accounts/OUs
backup_policy_description = getenv("BACKUP_POLICY_DESCRIPTION", "Backup Policy created by CfCT Lambda function.") # policy description
sqs_queue_url = getenv("SQS_QUEUE_URL") # URL of the FIFO queue used to process updates
retry_count = getenv("RETRY_COUNT", 3) # global count for retries during processing errors
sleep_time_seconds = getenv("SLEEP_TIME_SECONDS", 5) # global value for time to sleep when modifying values/during retries

# instantiate a logging tool
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# create aws clients
org_client = boto3.client('organizations')
s3_client = boto3.client('s3')
sqs_client = boto3.client('sqs')

# boolean to flag if backup policy files were deleted
deletion_flag = False

##################################################
# Helper function to test if a proposed Backup
# Policy exists within AWS Organizations.
##################################################
def test_policy_exists(policy_name):

    # boolean to check values and return
    exists = False
    
    # set retry flag for re-processing purposes
    retries = 0
    
    # add info the logs about what operation is being performed
    logger.info(f"Checking if policy named {policy_name} exists.")

    # set to a None value, which is only replaced if processing works
    policy_list = None
    
    # iterate until we max out; iterator set to value above max if processing is successful before max retries
    while retries < retry_count:
        # get the list of existing policies
        try:
            # sleep before starting attach since we might have concurrent operations occurring
            time.sleep(sleep_time_seconds)
            # get the list of existing backup policies
            response = org_client.list_policies(Filter='BACKUP_POLICY')
            policy_list = response['Policies']
            while 'NextToken' in response:
                response = org_client.list_policies(Filter='BACKUP_POLICY', NextToken=response['NextToken'])
                policy_list.extend(response['Policies'])
                
            # if we got a real value/list, can stop execution
            if policy_list is not None:
                retries = retry_count + 1
                
        except Exception as e:
            # known error situation
            if re.search('TooManyRequestsException', str(e)):
                retries += 1
                logger.info(f"Organizations operations pending. Adding additional wait period for retry.")
                # sleep to wait a bit longer
                time.sleep(sleep_time_seconds)
            else: 
                retries += 1
                logger.error(f"Error retrieving the list of existing backup policies. Exception is: {e}")
            

    try:
        # filter results to see if the 'Name' key exists in the list of policies provided
        match = list(filter(lambda policy: policy['Name'] == policy_name, policy_list))
        # if we get a match, set our boolean to True
        if len(match) > 0:
            exists = True
    except Exception as e:
        logger.error(f"Encountered an issue trying to find policies. Exception is: {e}")
    
    # return whether or not match was found
    return exists

# end function test_policy_exists

##################################################
# Helper function to get the data from an object 
# in S3 and return the jsonified output for use 
# with API calls.
##################################################
def get_s3_file_content(s3_bucket, s3_key):

    # check to see if we expect deleted objects, then avoid processing with failures
    if deletion_flag == True and target_list_file_name in s3_key:
        return None
    
    # otherwise process to get S3 object data
    else:
        try:
            logger.info(f"Attempting to retrieve data from {s3_key}")
            # get the data from our S3 object
            file_content = s3_client.get_object(Bucket=s3_bucket,Key=s3_key)['Body'].read()
        except Exception as e:
            # if we are supposed to be evaluating an object, but the key is empty, log the info
            if deletion_flag == False:
                logger.info(f"No data found for {s3_bucket}/{s3_key}.")
            return None
            
        # return jsonified file stuff
        return json.loads(file_content)

# end function get_s3_file_content

##################################################
# Helper function to get the list of policies
# and retrieve the ID of a policy when only 
# given the name.
##################################################
def get_policy_id(policy_name):

    
    # get a list of all the org backup policies
    try:
        response = org_client.list_policies(Filter='BACKUP_POLICY')
        policy_list = response['Policies']
        while 'NextToken' in response:
            response = org_client.list_policies(Filter='BACKUP_POLICY', NextToken=response['NextToken'])
            policy_list.extend(response['Policies'])
    except Exception as e:
        # return an empty value
        policy_list = None
        logger.error(f"Could not retrieve the list of current policies. Exception is: {e}")
    
    # assuming there are policies returned from our query, see if any match by name
    if policy_list is not None:
        # use filter for faster processing than iteration
        matched_policy = list(filter(lambda policy: policy['Name'] == policy_name, policy_list))
        # if there's a match, return the Id field
        if len(matched_policy) > 0:
            return matched_policy[0]['Id']
        # otherwise return an empty value
        else:
            return None
  # return empty value if all processing made it to here somehow
    else:
        return None

# end function get_policy_id


##################################################
# Helper function to get the list of targets that
# a Backup Policy is attached to.
##################################################
def get_attached_targets(policy_id):
    
    # query for list of targets of a given Policy Id
    try:
        response = org_client.list_targets_for_policy(PolicyId=policy_id)
        target_list = response['Targets']
        while 'NextToken' in response:
            response = org_client.list_policies(PolicyId=policy_id, NextToken=response['NextToken'])
            target_list.extend(response['Policies'])
        
    except Exception as e: 
        # return an empty value
        target_list = None
        logger.info(f"No targets found for {policy_id}.")
    
    # return the list (or None) for attached targets
    return target_list

# end function get_attached_targets

##################################################
# Helper function to attach an AWS Organizations
# Backup Policy to the targets provided in .json
# target_list_file_name
##################################################
def attach_backup_policy(target_id, policy_id):

    
    # set retry flag for re-processing purposes
    retries = 0

    # iterate until we max out; iterator set to value above max if processing is successful before max retries
    while retries < retry_count:
        try:
            logger.info(f"Attaching policy {policy_id} to target {target_id}")
            # sleep before starting attach since we might have concurrent operations occurring
            time.sleep(sleep_time_seconds)
            # attempt to attach the policy and capture response
            response = org_client.attach_policy(TargetId=target_id,PolicyId=policy_id)

            # if the operation succeeded, set the iterator above its max to end processing
            if response['ResponseMetadata']['HTTPStatusCode'] == 200:
                retries = retry_count + 1
        except Exception as e:
            # known (but OK) exception is if policy is already attached, then we don't need to do anything else
            if re.search('DuplicatePolicyAttachmentException', str(e)):
                retries = retry_count + 1
            # if processing did not complete, try again but log an error
            else:
                retries += 1
                logger.error(f"Encountered a problem attaching Backup Policy {policy_id} to Target {target_id}. Exception is {e}")

# end function attach_backup_policy

#################################################
# Helper function to detach an AWS Organizations
# Backup Policy from any targets it should no
# longer be attached to. This may be due to an
# update in the target definition list, or when
# a policy itself is deleted.
#################################################
def detach_backup_policy(target_id, policy_id):

    
    # set retry flag for re-processing purposes
    retries = 0

    # iterate until we max out; iterator set to value above max if processing is successful before max retries
    while retries < retry_count:
        try:
            logger.info(f"Detaching policy {policy_id} from target {target_id}")
            # sleep before starting attach since we might have concurrent operations occurring
            time.sleep(sleep_time_seconds)
            # attempt to detach the policy and capture response
            response = org_client.detach_policy(TargetId=target_id, PolicyId=policy_id)
            # if the operation succeeded, set the iterator above its max to end processing
            if response['ResponseMetadata']['HTTPStatusCode'] == 200:
                retries = retry_count + 1
        except Exception as e:
            # known (but OK) exception is if policy is NOT attached, then we don't need to do anything else
            if re.search('PolicyNotAttachedException', str(e)) is not None:
                retries = retry_count + 1
            # if processing did not complete, try again but log an error
            else:
                retries += 1
                logger.error(f"Encountered a problem detaching Backup Policy {policy_id} from Target {target_id}. Exception is {e}")

# end function detach_backup_policy

##################################################
# Helper function to manage attach and detach of
# Backup Policy from targets in AWS Organizations
# based on file changes (create, update, delete)
# to the Backup Policy definition or targets list.
##################################################
def update_backup_policy_attachments(s3_bucket, policy_name):

    # call the helper function to derive the Policy Id from a Name
    policy_id = get_policy_id(policy_name)

    # construct the object location from parameters 
    s3_file_location = policy_name + "/" + target_list_file_name

    # get the information from the file
    targets_json_data = get_s3_file_content(s3_bucket, s3_file_location)

    # get a list of targets the policy is already attached to
    existing_target_list = get_attached_targets(policy_id)

    # if we got a target definition file, process based on that
    if targets_json_data is not None:
        # iterate through all targets defined in the target definition .json
        for target in targets_json_data['targets']:
            # check for a match of the policy already assigned to the target
            if existing_target_list is not None and re.search(f"/{target}", json.dumps(existing_target_list)) is not None:
                logger.info(f"Target {target} already has policy {policy_name} attached.")
            # if it is not already attached, but is found here, it should be - so call the attach helper function
            else:
                attach_backup_policy(target, policy_id)
    # if we have no existing targets in the list, process based on that
    if existing_target_list is not None:
        # iterate through all the existing targets the policy is attached to
        for target in existing_target_list:
            # check for a match to see if the policy is attached to a target that is NOT in our target defintion .json and remove it
            if existing_target_list is not None and (targets_json_data is None or re.search(target['TargetId'], str(targets_json_data['targets']))==None) :
                detach_backup_policy(target['TargetId'], policy_id)

# end function update_backup_policy_attachments


##################################################
# Helper function to update an AWS Organizations
# Backup Policy based on changes to a policy
# definition. If a policy is deleted, it should
# also delete the policy.
##################################################
def delete_backup_policy(s3_bucket, policy_name, existing_target_list):
    
    
    # call the helper function to derive the Policy Id from a Name
    policy_id = get_policy_id(policy_name)

    # if we have a list of attached targets, but the delete function is being called, detach them all
    if existing_target_list is not None:
        for target in existing_target_list:
            time.sleep(sleep_time_seconds)
            detach_backup_policy(target['TargetId'], policy_id)

    # set retry flag for re-processing purposes
    retries = 0

    # making sure we did not get a bogus policy ID
    if policy_id is not None:
        # iterate until we max out; iterator set to value above max if processing is successful before max retries
        while retries < retry_count:
            try:
                logger.info(f"Deleting policy called {policy_name}, policy ID {policy_id}")
                # sleep before starting attach since we might have concurrent operations occurring
                time.sleep(sleep_time_seconds)
                # attempt to delete the policy
                org_client.delete_policy(PolicyId=policy_id)

                # use our existing helper to make sure the policy no longer exists. If not, it was deleted and we can end processing
                if test_policy_exists(policy_name) == False:
                    retries = retry_count + 1

            # if processing did not complete, try again but log an error
            except Exception as e:
                retries += 1
                logger.error(f"Encountered an issue deleting policy {policy_name}. Exception is: {e}")

# end function update_backup_policy

##################################################
# Helper function to create an AWS Organizations
# Backup Policy using definitions provided by the
# .json policy_definition_file_name
##################################################
def create_backup_policy(s3_bucket, policy_name):

    # derive the object location from parameters 
    s3_file_location = policy_name + "/" + policy_definition_file_name

    # get the jsonified data required to pass to the API
    policy_json_data = json.dumps(get_s3_file_content(s3_bucket, s3_file_location))

    # see if the policy exists already
    policy_exists = test_policy_exists(policy_name)
    if policy_exists == True:
        policy_id = get_policy_id(policy_name)
    
        
    # set retry flag for re-processing purposes
    retries = 0

    # if the policy has previously been created, but we have an update to the definition file, we want to update the policy content
    if policy_exists == True and policy_json_data is not None:
        # iterate until we max out; iterator set to value above max if processing is successful before max retries
        while retries < retry_count:
            try:
                logger.info(f"Updating policy called {policy_name} with policy definition in {policy_definition_file_name}")
                # sleep before starting attach since we might have concurrent operations occurring
                time.sleep(sleep_time_seconds)
                # attempt to update the policy
                response = org_client.update_policy(Content=policy_json_data,Description=backup_policy_description,Name=policy_name,PolicyId=policy_id)
                # if the operation succeeded, set the iterator above its max to end processing
                if response['ResponseMetadata']['HTTPStatusCode'] == 200:
                    retries = retry_count + 1
            # if processing did not complete, try again but log an error
            except Exception as e:
                retries += 1
                logger.error(f"Encountered an issue updating policy {policy_name}. Exception is: {e}")
    
    # if the policy does NOT exist but we have a definition file updated, create the new policy
    elif policy_exists == False and policy_json_data is not None:
        # iterate until we max out; iterator set to value above max if processing is successful before max retries
        while retries < retry_count:
            try: 
                logger.info(f"Creating backup policy called {policy_name} from policy definition in {policy_definition_file_name}")
                # sleep before starting attach since we might have concurrent operations occurring
                time.sleep(sleep_time_seconds)
                # attempt to create the policy
                response = org_client.create_policy(Content=policy_json_data,Description=backup_policy_description,Name=policy_name,Type='BACKUP_POLICY')
                # if the operation succeeded, set the iterator above its max to end processing
                if response['ResponseMetadata']['HTTPStatusCode'] == 200:
                    retries = retry_count + 1
            
            # if processing did not complete, try again but log an error
            except Exception as e:
                retries += 1
                logger.error(f"Encountered an issue creating the Backup Policy. The Exception is: {e}")

    # once the policy is updated, call the helper function to reconcile target attachment
    update_backup_policy_attachments(s3_bucket, policy_name)

# end function create_backup_policy

##################################################
# Main Lambda handler function. Event trigger
# should come from a SQS queue, which is populated
# by a child Lambda function that parses updates
# to backup policy files stored in S3.
##################################################
def lambda_handler(event, context):

    # log beginning of the handler event
    logger.info('event received: {}'.format(event))

    # get the receipt of the SQS message so we can delete it when finished processing
    receipt_handle = event['Records'][0]['receiptHandle']

    # get the relevant info into variables
    s3_bucket = event['Records'][0]['messageAttributes']['Bucket']['stringValue']
    updated_object = event['Records'][0]['messageAttributes']['UpdatedObject']['stringValue']
    policy_name = updated_object.split("/")[0]

    # create a variable from the globalized value
    global deletion_flag
    global retry_count
    global sleep_time_seconds

    # fix string values from CloudFormation
    retry_count = int(retry_count)
    sleep_time_seconds = int(sleep_time_seconds)

    # helpful info into the logs up front about which policy it is
    logger.info(f"Evaluating backup policy called {policy_name}")

    # a file was uploaded to S3 and processed by the child Lambda
    if 'Upload' in event['Records'][0]['messageAttributes']['Action']['stringValue']:
        # be certain we are in "create" mode to avoid skipped processing
        deletion_flag = False
        # create the policy from uploaded definition (will update if it already exists)
        try:
            create_backup_policy(s3_bucket, policy_name)
        except Exception as e:
            logger.error(f"Failure occurred processing uploaded file. Event info is: {e}.")
            raise

    # a file was deleted from S3 and processed by the child Lambda
    elif 'Delete' in event['Records'][0]['messageAttributes']['Action']['stringValue']:
        # operate in "delete" mode to avoid errors and processing of things we know should be gone
        deletion_flag = True

        # even though the child Lambda should not send .zip deletions to the queue, extra check to skip it
        if '.zip' in updated_object:
            logger.info(f"Deleted file is .zip archive. Skipping processing.")
        
        # otherwise we need to figure out if it was the targets definition or policy definition deleted
        else:
            try:
                # if it is the target list, we just want to reconcile the attachments with the updated targets
                if target_list_file_name in updated_object:
                    logger.info(f"Target definition file in S3 Bucket: {s3_bucket} at key: {updated_object} deleted.") 
                    update_backup_policy_attachments(s3_bucket, policy_name)

                # if the policy file is deleted, we want to delete the policy, too
                elif policy_definition_file_name in updated_object:
                    logger.info(f"Policy definition file in S3 Bucket: {s3_bucket} at key: {updated_object} deleted. Attempting to detach targets and delete the policy.")
                    delete_backup_policy(s3_bucket, policy_name, get_attached_targets(get_policy_id(policy_name)))
            except Exception as e:
                logger.error(f"Exception occurred with processing deleted object. Exception is: {e}")

    # after everything is processed, delete the SQS message
    sqs_client.delete_message(
        QueueUrl = sqs_queue_url,
        ReceiptHandle = receipt_handle
    )

# end of function lambda_handler
