#!/bin/bash

# usage:
# create_env arguments
# -ak|--aws-access-key <AWS_ACCESS_KEY_ID> (optional - taken from environment unless specified)
# -as|--aws-secret <AWS_SECRET_ACCESS_KEY> (optional - taken from environment unless specified)
# -ar|--aws-region <AWS_DEFAULT_REGION> (optional - taken from environment unless specified)
# -a|--application-name <application name> (mandatory)
# -e|--environment-name <environment name> (mandatory)
# -l|--language-id <language two letter identifier> (optional)
# -c|--country-id <country two letter identifier> (optional)
# <unique instance name> (optional)
# -v|--initial-version (optional)


for i in "$@"
do
case $i in
    -ak=*=*|--aws-access-key=*)
    aws_access_key="${i#*=}"
	export AWS_ACCESS_KEY=$aws_access_key
    shift # past argument=value
    ;;
    -as=*|--aws-secret=*)
    aws_secret="${i#*=}"
	export AWS_SECRET_ACCESS_KEY=$aws_secret
    shift # past argument=value
    ;;
    -ar=*|--aws-region =*)
    aws_region="${i#*=}"
	export AWS_DEFAULT_REGION=$aws_region
    shift # past argument=value
    ;;
    -a=*|--app-id=*)
    app_id="${i#*=}"
    shift # past argument=value
    ;;
    -e=*|--environment-name=*)
    environment_name="${i#*=}"
    shift # past argument=value
    ;;
    -l=*|--language-id=*)
    language_id="${i#*=}"
    shift # past argument=value
    ;;
    -c=*|--country-id =*)
    country_id="${i#*=}"
    shift # past argument=value
    ;;
    -i|--instance-name )
    instance_name="${i#*=}"
    shift # past argument with no value
    ;;
    -v|--initial-version)
    initial_version="${i#*=}"
    shift # past argument with no value
    ;;
    *)
          # unknown option
    ;;
esac

# if no region was specified, take it from shell environment if exists, otherwise set to us-east-1 (AWS Default region)
if [-z "$aws_region"] then
	if [-z "$AWS_ACCESS_KEY_ID"]
		then
			aws_region=$AWS_DEFAULT_REGION
	else
		aws-region=us-west-1
	fi
fi

projectname=cwebdevleon
report() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}


appname="$app_id-$environment_name"
# add optional parameters to appname if they exist
if ! [-z "$language_id"]; then
	appname+="-$language_id"
fi
if ! [-z "$country_id"]; then
	appname+="-$country_id"
fi
if ! [-z "$instance_name"]; then
	appname+="-$instance_name"
fi


cfblue="$appname-cloudfront-blue"
cfgreen="$appname-cloudfront-green"
cftest="$appname-cloudfront-test"
cfmodifypolicy="$appname-cloudfront-distribution-modify-policy"
bucketwritepolicy="$appname-jenkins-bucketwrite-policy"
bucketreadoai="$appname-cf-bucketread-access-identity.s3.amazonaws.com"
cfmodifyuser="$appname-cloudfrontdistribution-modify-policy-user"
jenkinsbucketwriteuser="$appname-jenkins-bucketwrite-policy-user"
cfbucketreadpolicy="$appname-cf-bucketread-policy-user"
bucketname="$appname-bucket"
bucketarn="arn:aws:s3:::$bucketname"

outputlog=log/$appname$(date +%Y-%m-%d.%H.%M.%S).log
# rm $outputlog

# report output to stdout and log
report() {
echo $*
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >>$outputlog
}

# runs command and reports output
runcommand () { 

	command=$1
	report running $command
	output=$($command 2>&1)
	report $output
	}

# report variables
report app_id=$app_id
report environment_name=$environment_name
report language_id=$language_id
report country_id=$country_id
report instance_name=$instance_name
report appname=$appname
report cfblue=$cfblue
report cfgreen=$cfgreen
report cftest=$cftest
report cfmodifypolicy=$cfmodifypolicy
report bucketwritepolicy=$bucketwritepolicy
report bucketreadpolicy=$bucketreadpolicy
report cfmodifyuser=$cfmodifyuser
report bucketreadoai=$bucketreadoai
report jenkinsbucketwriteuser=$jenkinsbucketwriteuser
report bucketname=$bucketname
report initial_version=$initial_version

# create S3 Bucket
runcommand="aws s3api create-bucket --bucket $bucketname --region $aws_region --create-bucket-configuration LocationConstraint=$aws_region ----acl private"

# create folder for initial_version
runcommand="aws s3api put-object --bucket $bucketname --key $initial_version/"

# create jenkins user for s3 write
runcommand="aws iam create-user --username $jenkinsbucketwriteuser"
jenkinsbucketwriteuserarn=`aws iam get-user --user-name $jenkinsbucketwriteuser --output text --query '*.[Arn]'`

# create policy for jenkinsbucketwriteuser and attach to user
# create bucket write policy
read -r -d '' bucketwritepolicydoctemplate << EOM
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:DeleteObject**",
                "s3:ListObject*"
				"s3:PutObject**"
            ],
            "Resource": [
                "arn:aws:s3:::mybucket/*"
            ]
        }
    ]
}
EOM
#substitute mybucket for $bucketname
bucketwritepolicydoc="${bucketwritepolicydoctemplate/mybucket/$bucketname}"
report bucketwritepolicydoc=$bucketwritepolicydoc

# Create Origin Access ID for S3 bucket
	# Create Origin
	
# Create Cloudfront Blue Distribution
	# Origin=$bucketname.s3.amazonaws.com
	# OriginPath=
# Create Cloudfront Green Distribution
# Create Cloudfront Test Distribution







output=$(aws iam create-role --role-name $bucketrole --assume-role-policy-document file://$bucketpolicydoc)
echo $(date +%Y-%m-%d.%H.%M.%S) output=$output>>$outputlog
roleArn=$output
echo $(date +%Y-%m-%d.%H.%M.%S)    Creating IAM User>>$outputlog
output=$(aws iam create-user --user-name $bucketuser  --permissions-boundary $roleArn)
echo $(date +%Y-%m-%d.%H.%M.%S) output=$output>>$outputlog



