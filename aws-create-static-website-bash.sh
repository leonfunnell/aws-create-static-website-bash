#!/bin/bash


usage(){
echo "
Creates hosting environment for static website on AWS with Blue/Green/Test deploy stages
Creates:
- S3 Bucket
- Blue, Green and Test CloudFront Distributions
- IAM User and policy for updating S3 bucket from Jenkins or other CI tool
- IAM User and policy for updating CF distributions
- Route53 DNS with 50/50 round-robin between Blue and Green distributions

Requires:
- AWS CLI - AWS Command Line Interface
- jq JSON Parser
- sed Stream editor

Instructions for use:
1. Specify application-name and environment-name as a minimum.  The bucket will be created with a folder called application-name/initial-version.  initial-version will default to 0.0.1 if unspecified
2. All three CF distros will point to S3://bucketname/application-name/initial-version/
3. Upload your website files to S3://bucketname/application-name/initial-version/ (e.g. S3://mybucket/cweb/0.0.1/ to make your website live.  Ensure you have an index.html or similar
4. Your app will be available via both test-url and production-url

To upgrade to a new release:
1. Upload website to a new version folder (e.g. S3://mybucket/cweb/0.0.2/)
2. Using application-name-cf-user, create a new origin in the Test CF distro pointing to the above folder
3. Change behaviour of Test distro to the new behaviour
4. Test your website on test-url
5. Repeat the procedure above for the Blue distro
6. 50% of new connectiontraffic will be directed to the new version.
7. If your users are happy, then repeat for the Green distro


 -h|--help Help (this message)
 -ak|--aws-access-key=<AWS_ACCESS_KEY_ID> (optional - taken from environment unless specified)
 -as|--aws-secret=<AWS_SECRET_ACCESS_KEY> (optional - taken from environment unless specified)
 -ar|--aws-region=<AWS_DEFAULT_REGION> (optional - taken from environment unless specified)
 -a|--application-name=<application name> (mandatory)
 -e|--environment-name=<environment name> (mandatory)
 -tu|--test-url=<test url> (optional)
 -pu|--production-url=<production url> (optional)
 -lang|--language-i=<language two letter identifier> (optional)
 -c|--country-id=<country two letter identifier> (optional)
 -i|--instance-name=<unique instance name> (optional)
 -v|--initial-version=<initial version number>(optional)
 -s|--silent=true (optional - prevent screen output)
 -l|--log-directory=<directory for logfiles> (optional)"
}

# check dependencies
if ! [ -x "$(command -v jq)" ]; then 
  echo "ERROR: jq is not installed!  Please install jq!";
  dependencyfail=true;
fi

if ! [ -x "$(command -v aws)" ]; then 
  echo "ERROR: AWS CLI is not installed!  Please install AWS CLI!";
	dependencyfail=true;
fi

if ! [ -x "$(command -v sed)" ]; then 
  echo "ERROR: sed is not installed!  Please install sed!";
  	dependencyfail=true;
fi
if [ $dependencyfail ]; then
	usage
	exit 1
fi

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
        -tu|--test-url)
        testurl=$VALUE
        ;;
        -pu|--production-url)
        produrl=$VALUE
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
        -l|--log-diretory)
        logpath=$VALUE
        ;;
        -s|--silent)
        silent="true"
        ;;          
        *)
            echo "ERROR: unknown parameter \"$PARAM\""
            usage
            exit 1
            ;;
    esac
    shift
done

if [ ! $app_id ] || [ ! $environment_name ]; then
     echo "ERROR: missing parameters!";
     usage;
     exit 1;
fi

if [ ! $initial_version ]; then
    initial_version="0.0.1";
fi

# if no AWS region was specified, take it from shell environment if exists, otherwise set to us-east-1 (AWS Default region)
if [ ! $aws_region ]; then
     if [ ! "AWS_DEFAULT_REGION" ]; then
          aws_region=$AWS_DEFAULT_REGION;
     else
          aws_region="us-west-1";
     fi
fi

# function to output results to STDOUT and/or logfile
report() {
    if [ $logpath ]; then
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2 >> $logpath;
    fi
    if [ ! $silent ]; then
        echo "$*";
    fi
}

appname="$app_id"
appname+="-$environment_name"
# add optional parameters to appname if they exist
if ! [ -z "$language_id" ]; then
     appname+="-$language_id";
fi
if ! [ -z "$country_id" ]; then
     appname+="-$country_id";
fi
if ! [ -z "$instance_name" ]; then
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
jenkinsbucketwriteuser="$appname-jenkins-bucketwrite-user"
cfbucketreadpolicy="$appname-cf-bucketread-policy-user"
bucketname="$appname-bucket"
bucketarn="arn:aws:s3:::$bucketname"

#initialise logpath if specified
if [ $logpath ]; then
    outputlog=$logpath/$appname$(date +%Y-%m-%d.%H.%M.%S).log;
    if [ ! -d $logpath ]; then
       mkdir -p $logpath;
    fi
fi


# function to report output to stdout and log
report() {
     # echo output to stdout if silent flag not set
    if [ ! $silent ]; then
        echo "$*";
    fi
    if [ $logpath ]; then
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >>$outputlog;
    fi
}

# runs command and reports output
runcommand () {
    command="$*"
    report "running $command"
    if output=$($command 2>&1); then
        report "$output";
    else
        rc=$?;
        report "ERROR #$rc, $output";
        exit 1;
    fi
     }
     
runcommandescaped ()
{
    command="$*";
    report "running $command";
    if output=$(command 2>&1); then
        report "$output";
    else
        rc=$?;
        report "ERROR #$rc, $output";
        exit 1;
    fi
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

#get AWS Account ID for ARN construction
awsaccountid=$(aws ec2 describe-security-groups --query 'SecurityGroups[0].OwnerId' --output text)

# create S3 Bucket
runcommand "aws s3api create-bucket --bucket $bucketname --region $aws_region --create-bucket-configuration LocationConstraint=$aws_region --acl private"

# block public access for S3 bucket
read -e -r -d '' bucketblockpublictemplate << EOM
{
    "BlockPublicAcls":true,
    "IgnorePublicAcls":true,
    "BlockPublicPolicy":true,
    "RestrictPublicBuckets":true
}
EOM

runcommandescaped "`aws s3api put-public-access-block --bucket $bucketname --public-access-block-configuration "$bucketblockpublictemplate"`"

# create folder for initial_version
runcommand "aws s3api put-object --bucket $bucketname --key $initial_version/"
# create folder structure for website logs
runcommand "aws s3api put-object --bucket $bucketname --key website-logs/test/"
runcommand "aws s3api put-object --bucket $bucketname --key website-logs/blue/"
runcommand "aws s3api put-object --bucket $bucketname --key website-logs/green/"


# create jenkins user for s3 write
runcommand "aws iam create-user --user-name $jenkinsbucketwriteuser"

# create access-key for Jenkins
runcommand "aws iam create-access-key --user-name $jenkinsbucketwriteuser"

# generate ARN of user for policy
jenkinsbucketwriteuserarn="arn:aws:iam::$awsaccountid:user/$jenkinsbucketwriteuser"
#jenkinsbucketwriteuserarn=`aws iam get-user --user-name $jenkinsbucketwriteuser --output text --query '*.[Arn]'`
report "jenkinsbucketwriteuserarn=$jenkinsbucketwriteuserarn"

# create policy for jenkinsbucketwriteuser and attach to user
# create bucket write policy
read -e -r -d '' bucketwritepolicydoctemplate << EOM
{
    "Version": "2012-10-17",
        "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:DeleteObject**",
                "s3:ListBucket",
                "s3:PutObject*"
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
runcommandescaped "`aws iam create-policy --policy-name $bucketwritepolicy --policy-document "$bucketwritepolicydoc"`"
bucketwritepolicyarn="arn:aws:iam::$awsaccountid:policy/$bucketwritepolicy"
report "bucketwritepolicyarn=$bucketwritepolicyarn"

# attach bucketwrite-policy to jenkinsbucketwriteuser
report '"aws iam attach-user-policy --user-name $jenkinsbucketwriteuser --policy-arn "$bucketwritepolicyarn"' 

# Create Origin Access ID for S3 bucket
accessidentity="access-identity-$bucketname.s3.$aws_region.amazonaws.com"
report "accessidentity=$accessidentity"
read -e -r -d '' s3accessidconfigtemplate << EOM
{
    "CallerReference": "OAIComment",
    "Comment": "OAIComment"
}
EOM


#substitute OAIComment for $accessidentity
s3accessid=`echo "$s3accessidconfigtemplate" | sed "s/OAIComment/$bucketname/"`
#s3accessid="${s3accessidconfigtemplate/OAIComment/$bucketname}"

report "s3accessid=$s3accessid"
runcommandescaped "`aws cloudfront create-cloud-front-origin-access-identity  --cloud-front-origin-access-identity-config "$s3accessid"`"
# Get ID of Origin Access Identity
OAI=$(aws cloudfront list-cloud-front-origin-access-identities | jq '.CloudFrontOriginAccessIdentityList.Items | .[]| select(.Comment=="$bucketname").Id')


# Create Origin
read -e -r -d '' cfdistroconfigtemplate << EOM
{
    "ETag": "E21B74DNW5JBWL",
    "DistributionConfig": {
        "CallerReference": "cli-1605554712-103500",
        "Aliases": {
            "Quantity": 0
        },
        "DefaultRootObject": "",
        "Origins": {
            "Quantity": 1,
            "Items": [
                {
                    "Id": "ifggzzzhg-jassfe-bucket.s3.amazonaws.com-1605554712-125426",
                    "DomainName": "ifggzzzhg-jassfe-bucket.s3.amazonaws.com",
                    "OriginPath": "/0.0.1",
                    "CustomHeaders": {
                        "Quantity": 0
                    },
                    "S3OriginConfig": {
                        "OriginAccessIdentity": "origin-access-identity/cloudfront/E1S112VUAMJTF5"
                    }
                }
            ]
        },
        "OriginGroups": {
            "Quantity": 0
        },
        "DefaultCacheBehavior": {
            "TargetOriginId": "ifggzzzhg-jassfe-bucket.s3.amazonaws.com-1605554712-125426",
            "ForwardedValues": {
                "QueryString": false,
                "Cookies": {
                    "Forward": "none"
                },
                "Headers": {
                    "Quantity": 0
                },
                "QueryStringCacheKeys": {
                    "Quantity": 0
                }
            },
            "TrustedSigners": {
                "Enabled": false,
                "Quantity": 0
            },
            "ViewerProtocolPolicy": "allow-all",
            "MinTTL": 0,
            "AllowedMethods": {
                "Quantity": 2,
                "Items": [
                    "HEAD",
                    "GET"
                ],
                "CachedMethods": {
                    "Quantity": 2,
                    "Items": [
                        "HEAD",
                        "GET"
                    ]
                }
            },
            "SmoothStreaming": false,
            "DefaultTTL": 86400,
            "MaxTTL": 31536000,
            "Compress": false,
            "LambdaFunctionAssociations": {
                "Quantity": 0
            },
            "FieldLevelEncryptionId": ""
        },
        "CacheBehaviors": {
            "Quantity": 0
        },
        "CustomErrorResponses": {
            "Quantity": 0
        },
        "Comment": "MyComment",
        "Logging": {
            "Enabled": false,
            "IncludeCookies": false,
            "Bucket": "",
            "Prefix": ""
        },
        "PriceClass": "PriceClass_All",
        "Enabled": true,
        "ViewerCertificate": {
            "CloudFrontDefaultCertificate": true,
            "MinimumProtocolVersion": "TLSv1",
            "CertificateSource": "cloudfront"
        },
        "Restrictions": {
            "GeoRestriction": {
                "RestrictionType": "none",
                "Quantity": 0
            }
        },
        "WebACLId": "",
        "HttpVersion": "http2",
        "IsIPV6Enabled": true
    }
}
EOM



# Create Cloudfront Blue Distribution



origin="$bucketname.s3.amazonaws.com/"
runcommand="aws cloudfront create-distribution --origin-domain-name $origin"

# OriginPath=/$appname/$initial_version
# Create Cloudfront Green Distribution
# Create Cloudfront Test Distribution

#Create Lambda Function to update cloudfront distributions
