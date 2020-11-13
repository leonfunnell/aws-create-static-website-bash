#!/bin/bash

# usage:
# create_env arguments
# -ak|--aws-access-key <AWS_ACCESS_KEY_ID> (optional - taken from environment unless specified)
# -as|--aws-secret <AWS_SECRET_ACCESS_KEY> (optional - taken from environment unless specified)
# -ar|--aws-region <AWS_DEFAULT_REGION> (optional - taken from environment unless specified)
# -a|--application-name <application name> (mandatory)
# -e|--environment-name <environment name> (mandatory)
# -lang|--language-id <language two letter identifier> (optional)
# -c|--country-id <country two letter identifier> (optional)
# -i|--instance-name <unique instance name> (optional)
# -v|--initial-version (optional)
# -s|--silent (optional - prevent screen output)
# -l|--logpath <path for logfiles> (optional)


# parse parameters
while [ "$1" != "" ]; do
    PARAM=`echo $1 | awk -F= '{print $1}'`
    VALUE=`echo $1 | awk -F= '{print $2}'`
    case $PARAM in
        -h | --help)
            usage
            exit
            ;;
        -ak|--aws-access-key)
        aws_access_key=$VALUE
		export AWS_ACCESS_KEY=$aws_access_key
            ;;
        -as|--aws-secret)
        aws_secret=$VALUE
        export AWS_SECRET_ACCESS_KEY=$aws_secret
        ;;
        -ar|--aws-region)
        aws_region=$VALUE
        export AWS_DEFAULT_REGION=$aws_region
        ;;
        -a|--application-name)
        app_id=$VALUE
        echo "application-name=$app_id"
        ;;
        -e|--environment-name)
        environment_name=$VALUE
        echo  "environment-name=$environment_name"
        ;;
        -lang|--language-id)
        language_id=$VALUE
        ;;
        -c|--country-id)
        country_id=$VALUE
        ;;
        -i|--instance-name)
        instance_name=$VALUE
        ;;
        -v|--initial-version)
        initial_version=$VALUE
        ;;
        -l|--logpath)
        logpath=$VALUE
        ;;
        -s|--silent)
        silent=true
        ;;			
        *)
            echo "ERROR: unknown parameter \"$PARAM\""
            usage
            exit 1
            ;;
    esac
    shift
done

# if no AWS region was specified, take it from shell environment if exists, otherwise set to us-east-1 (AWS Default region)
if [ ! $aws_region ]; then
     if [ ! "AWS_DEFAULT_REGION"]; then
          aws_region=$AWS_DEFAULT_REGION;
     else
          aws-region="us-west-1";
     fi
fi

# function to output results to STDOUT and/or logfile
report() {
	if [ ! $logpath ]; then
		echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2;
	fi
	if [ ! $silent ]; then
		echo "$*";
	fi
}

appname="$app_id"
appname+="-$environment_name"
echo "Line 90 - appname=$appname"
# add optional parameters to appname if they exist
if ! [-z "$language_id"]; then
     appname+="-$language_id";
fi
if ! [-z "$country_id"]; then
     appname+="-$country_id";
fi
if ! [-z "$instance_name"]; then
     appname+="-$instance_name";
fi

#AWS resource parameters
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

#initialise logpath if specified
if [ ! $logpath ]; then
     if [ ! -d $logpath ]; then
        mkdir -p $logpath;
    fi
    outputlog=$logpath/$appname$(date +%Y-%m-%d.%H.%M.%S).log;
fi

# function to report output to stdout and log
report() {
     # echo output to stdout if silent flag not set
    if [ "$silent" != true ]; then
        echo $*;
    fi
    if [ ! "$logpath" ]; then
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >>$outputlog;
    fi
}

# runs command and reports output
runcommand () {
     command="$*"
     report "running $command"
     output="$($command 2>&1)"
     report "$output"
     }

# report variables
report "app_id=$app_id"
report "environment_name=$environment_name"
report "language_id=$language_id"
report "country_id=$country_id"
report "instance_name=$instance_name"
report "appname=$appname"
report "cfblue=$cfblue"
report "cfgreen=$cfgreen"
report "cftest=$cftest"
report "cfmodifypolicy=$cfmodifypolicy"
report "bucketwritepolicy=$bucketwritepolicy"
report "bucketreadpolicy=$bucketreadpolicy"
report "cfmodifyuser=$cfmodifyuser"
report "bucketreadoai=$bucketreadoai"
report "jenkinsbucketwriteuser=$jenkinsbucketwriteuser"
report "bucketname=$bucketname"
report "initial_version=$initial_version"

# create S3 Bucket
runcommand="aws s3api create-bucket --bucket $bucketname --region $aws_region --create-bucket-configuration LocationConstraint=$aws_region ----acl private"

# create folder for initial_version
runcommand="aws s3api put-object --bucket $bucketname --key $initial_version/"

# create jenkins user for s3 write
runcommand="aws iam create-user --username $jenkinsbucketwriteuser"
# get ARN of user for policy
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
report "bucketwritepolicydoc=$bucketwritepolicydoc"
# create bucketwrite-policy
# attach bucketwrite-policy to jenkinsbucketwriteuser

# Create Origin Access ID for S3 bucket
# Create Origin

# Create Cloudfront Blue Distribution
# Origin=$bucketname.s3.amazonaws.com
# OriginPath=
# Create Cloudfront Green Distribution
# Create Cloudfront Test Distribution

#Create Lambda Function to update cloudfront distributions

