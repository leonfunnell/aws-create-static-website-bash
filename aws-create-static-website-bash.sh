#!/bin/bash


usage(){
echo "
Creates hosting environment for static website on AWS with Blue/Green/Test deploy stages
Creates:
- S3 Bucket
- Blue, Green and Test CloudFront Distributions
- IAM User and policy for updating S3 bucket from jenkins or other CI tool
- IAM User and policy for updating CF distributions
- Route53 DNS with 50/50 round-robin between Blue and Green distributions

Requires:
- AWS CLI - AWS Command Line Interface
- jq JSON Parser

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
 -rz|--route53-zone=<route53 hosted zones, comma separated, i.e. hh.abc.com,kk.abc.com > (optional)
 -ra|--route53autochain (automatically chain subdomain to an existing domain if it exists in the same account (i.e if abc.com owned, can chain hh.abc.com,kk.abc.com so they are resolvable)
 -cert|--certificate-name=<certificate FQDN name/wildcard, i.e -cert=*.abc.com> (optional)
 -certsans|--certificate-subject-alternate-names=<certificate subject alternate names, comma separated, i.e -certsans=*.hh.abc.com,*.kk.abc.com > (optional)
 -lang|--language-id=<language two letter identifier> (optional)
 -c|--country-id=<country two letter identifier> (optional)
 -i|--instance-name=<unique instance name> (optional)
 -v|--initial-version=<initial version number>(optional)
 -q|--quiet (optional - prevent screen output)
 -l|--log-directory=<directory for logfiles> (optional)
 -c|--clean-up (optional) - remove all previously deployed assets
 -p|--initial-package=<path to package to upload> (optional)  e.g. ../pagedir/ (uploads full directory)
 -ln|--emit-line-numbers - emit script line numbers and caller references for debugging
 -ej|--emit-json - emit json parameters used
 -temp|--temp-directory=<directory for temp files> (optional, uses /tmp if not specified)
 -ex|--exit-on-error - exit script on error condition and don't proceed any further
"
}

# report output to stdout and/or logfile
report () { 
    if [ "$emitlinenumbers" ]; then
        # include line numbers and calling function if emit-line-numbers set
        linereport="${FUNCNAME[1]}";
            # if caller was runcommand and a second parameter was included then report line number of it's caller
            if [[ "$linereport" == *"runcommand"* ]] && [[ "$1" ]]; then
                linereport="${BASH_LINENO[1]}:";
            else
                linereport="${BASH_LINENO[0]}:";
            fi;
    fi;
    if [ ! "$silent" ]; then
        # echo output to stdout if no silent flag set
        echo "$linereport$*";
    fi;
    if [ "$logpath" ]; then
        # send to outputlog if output-log is set
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $linereport$*" >>"$outputlog";
    fi;
}

# runs command and reports output
runcommand () {
    command="$*";
    report "running $command";
    if output=$($command 2>&1); then
        report "output:";
        report "$output";
    else
        rc=$?;
        report "ERROR #$rc, ${BASH_LINENO[*]}: $output";
        if [[ "${SHLVL}" -gt 1 ]] && [[ "$exitonerror" ]]; then
            #check SHLLVL to prevent closing bash shell if script is pasted in immediate mode
            report "exiting..."
            exit 1;
        fi;
    fi;
}

report "----------------------------------------------------------------------------------------"
report "|                 AWS Static Website Hosting Environment Builder                       |"
report "----------------------------------------------------------------------------------------"
report " "


# check dependencies
if ! [ -x "$(command -v jq)" ]; then 
  report "ERROR: jq is not installed!  Please install jq (sudo apt-get install jq)!";
  dependencyfail=true;
fi

if ! [ -x "$(command -v aws)" ]; then 
  report "ERROR: AWS CLI is not installed!  Please install AWS CLI (sudo apt-get install awscli)!";
    dependencyfail=true;
fi

if [ $dependencyfail ]; then
    usage
    exit 1
fi

report "parameters:"

# parse parameters
while [ "$1" != "" ]; do
    PARAM="${1%=*}";
    VALUE="${1#*=}";
    case $PARAM in
        -h | --help)
            usage
            exit
            ;;
        -ak|--aws-access-key)
        aws_access_key=$VALUE
        export AWS_ACCESS_KEY=$aws_access_key
        report "AWS_ACCESS_KEY=$AWS_ACCESS_KEY"
            ;;
        -as|--aws-secret)
        aws_secret=$VALUE
        export AWS_SECRET_ACCESS_KEY=$aws_secret
        report "AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxx"
        ;;
        -ar|--aws-region)
        aws_region=$VALUE
        export AWS_DEFAULT_REGION=$aws_region
        report "AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"
        ;;
        -cert|--certificate-name)
        certname=$VALUE
        report "certname=$certname"
        ;;
        -certsans|--certificate-subject-alternate-names)
        tmpcertsans=$VALUE
        certsans=""
        while [ "$tmpcertsans" ]; do
            # convert commas to spaces as required in Route53
            field=${tmpcertsans##*,};
            certsans="$field $certsans";
            if [ "$tmpcertsans" = "$field" ]; then
                tmpcertsans="";
            else
                tmpcertsans="${tmpcertsans%,*}"
            fi;
        done
        report "certsans=$certsans"
        ;;
        -a|--application-name)
        app_id=$VALUE
        report "app_id=$app_id"
        ;;
        -ln | --emit-line-numbers)
        emitlinenumbers="true"
        report "emitlinenumbers=$emitlinenumbers"
		;;
        -ej|--emit-json)
        emitjson="true"
        report "emitjson=$emitjson"
        ;;
        -e|--environment-name)
        environment_name=$VALUE
        report "environment_name=$environment_name"
        ;;
        -tu|--test-url)
        testurl=$VALUE
        report "testurl=$testurl"
        ;;
        -pu|--production-url)
        produrl=$VALUE
        report "produrl=$produrl"
        ;;
        -rz|--route53-zone)
        route53zones=$VALUE
        report "route53zones=$route53zones"
        ;;
        -ra|--route53autochain)
        routeautochain="true"
        report "routeautochain=$routeautochain"
        ;;
        -lang|--language-id)
        language_id=$VALUE
        report "language_id=$language_id"
        ;;
        -co|--country-id)
        country_id=$VALUE
        report "country_id=$country_id"
        ;;
        -i|--instance-name)
        instance_name=$VALUE
        report "instance_name=$instance_name"
        ;;
        -v|--initial-version)
        initial_version=$VALUE
        report "initial_version=$initial_version"
        ;;
        -p|--initial-package)
        packagedirectory=$VALUE
        report "packagedirectory=$packagedirectory"
        ;;
        -q|--quiet|-s|--silent)
        silent="true"
        report "silent=$silent"
        ;;          
		-c|--clean-up)
		cleanup="true"
        report "cleanup=$cleanup"
        ;;
        -l|--log-directory)
        logpath=$VALUE
        outputlog=$logpath/$appname$(date +%Y-%m-%d.%H.%M.%S).log;
        if [ ! -d "$logpath" ]; then
           mkdir -p "$logpath";
        fi
        report "logpath=$logpath"
        report "outputlog=$outputlog"
        ;;
        -temp|--temp-directory)
        tempdir=$VALUE
        ;;
        -ex|--exit-on-error)
        exitonerror="true"
        report "exitonerror=$exitonerror"
        ;;
        *)
            report "ERROR: unknown parameter \"$PARAM\""
            usage
            exit 1
            ;;
    esac
    shift
done

if [ ! "$app_id" ] || [ ! "$environment_name" ]; then
     echo "ERROR: missing parameters!";
     usage;
     exit 1;
fi

if [ "$initial_version" ]; then
    report "initial_version=$initial_version";
else
    initial_version="0.0.1";
    report "initial_version defaulting to $initial_version as it was not specified";
fi

# if no AWS region was specified, take it from shell environment if exists, otherwise set to us-east-1 (AWS Default region)
if [ "$aws_region" ]; then
    AWS_DEFAULT_REGION="$aws_region";
else
     if [ "$AWS_DEFAULT_REGION" ]; then
          aws_region=$AWS_DEFAULT_REGION;
     else
          aws_region="us-east-1";
          AWS_DEFAULT_REGION="$aws_region";
          report "AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION (defaulting as not specified)";
     fi;
fi


if [ "$tempdir" ]; then
    # remove trailing / (slash) if required
    length="${#tempdir}";
    lastchar="${tempdir:length-1:1}";
    if [ "$lastchar" = "/" ]; then
        tempdir="${tempdir:0:length-1}";
    fi;
else
    # set tempdir if not specified
    tempdir="/tmp";
fi
    report "tempdir=$tempdir"
if [ ! -w "$tempdir/" ] ; then 
    # check if tempdir is writable, exit with error if not
    report "ERROR: temp directory $tempdir is not writable!"
    exit 1;
fi


#get AWS Account ID for ARN construction
awsaccountid=$(aws ec2 describe-security-groups --query 'SecurityGroups[0].OwnerId' --output text)
report "awsaccountid=$awsaccountid"

# period for retrying long-running AWS operations
waitperiod=30

cfdistronames="blue,green,test"
appname="$app_id"
appname+="-$environment_name"
# add optional parameters to appname if they exist
if [ "$language_id" ]; then
     appname+="-$language_id";
fi
if [ "$country_id" ]; then
     appname+="-$country_id";
fi
if  [ "$instance_name" ]; then
     appname+="-$instance_name";
fi
report "appname=$appname"

#AWS resource parameters
cfblue="$appname-cloudfront-blue"
report "cfblue=$cfblue"

# public DNS server address to use for DNS record lookups
publicdns=8.8.8.8 # Google public DNS
report  "publicdns=$publicdns"

cfgreen="$appname-cloudfront-green"
report "cfgreen=$cfgreen"

cftest="$appname-cloudfront-test"
report "cftest=$cftest"

cfmodifypolicy="$appname-cloudfront-distribution-modify-policy"
report "cfmodifypolicy=$cfmodifypolicy"

bucketwritepolicy="$appname-jenkins-bucketwrite-policy"
report "bucketwritepolicy=$bucketwritepolicy"

bucketreadoai="$appname-cf-bucketread-access-identity.s3.amazonaws.com"
report "bucketreadoai=$bucketreadoai"

cfmodifyuser="$appname-cloudfrontdistribution-modify-policy-user"
report "cfmodifyuser=$cfmodifyuser"

jenkinsbucketwriteuser="$appname-jenkins-bucketwrite-user"
report "jenkinsbucketwriteuser=$jenkinsbucketwriteuser"

jenkinsbucketwriteuserarn="arn:aws:iam::$awsaccountid:user/$jenkinsbucketwriteuser";
report "jenkinsbucketwriteuserarn=$jenkinsbucketwriteuserarn";

bucketwritepolicyarn="arn:aws:iam::$awsaccountid:policy/$bucketwritepolicy";
report "bucketwritepolicyarn=$bucketwritepolicyarn"

# Define Origin Access ID for S3 bucket
originaccessidentity="access-identity-$bucketname.s3.$aws_region.amazonaws.com"
report "originaccessidentity=$originaccessidentity"

cfbucketreadpolicy="$appname-cf-bucketread-policy-user"
report "cfbucketreadpolicy=$cfbucketreadpolicy"

bucketname="$appname-bucket"
report "bucketname=$bucketname"

bucketaddress="$bucketname.s3.amazonaws.com"
report "bucketaddress=$bucketaddress"

bucketarn="arn:aws:s3:::$bucketname"
report "bucketarn=$bucketarn"

# JSON Templates

# Template to block public access for S3 bucket
read -e -r -d '' bucketblockpublictemplate << EOM
{
    "BlockPublicAcls":true,
    "IgnorePublicAcls":true,
    "BlockPublicPolicy":true,
    "RestrictPublicBuckets":true
}
EOM

echo "$bucketblockpublictemplate" > /tmp/bucketblockpublic.json

# Template for bucket write policy
read -e -r -d '' bucketwritepolicytemplate << EOM
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

# Template for bucket read policy for CloudFront Origin Access Identity
read -e -r -d '' s3grantaccesstemplate << EOM
{
    "Version": "2012-10-17",
    "Id": "AllowCloudfrontAccessToMyS3Bucket",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity XXXXXXX"
            },
            "Action": "s3:GetObject",
            "Resource": "MyBucketARN"
        }
    ]
}
EOM

# Template for CloudFront Config
read -e -r -d '' cfdistroconfigtemplate << EOM
{
  "CallerReference": "MyCallerReference",
  "Aliases": {
      "Quantity": 0
  },
  "DefaultRootObject": "index.html",
  "Origins": {
      "Quantity": 1,
      "Items": [
          {
              "Id": "MyBucketURL",
              "DomainName": "MyBucketURL",
              "OriginPath": "/MyPath",
              "CustomHeaders": {
                  "Quantity": 0
              },
              "S3OriginConfig": {
                  "OriginAccessIdentity": "origin-access-identity/cloudfront/MyOAI"
              }
          }
      ]
  },
  "OriginGroups": {
      "Quantity": 0
  },
  "DefaultCacheBehavior": {
      "TargetOriginId": "MyBucketURL",
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
  "Comment": "",
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
EOM

read -e -r -d '' r53addrecordtemplate << EOM
{
    "Changes": [            
        {
        "Action": "UPSERT",
        "ResourceRecordSet":{
            "Name": "recordname",
            "Type": "recordtype",
            "TTL": 300
          }
        }
    ]
}
EOM

report " "
report "----------------------------------------------------------------------------------------"
report " "

if [ ! "$cleanup" ]; then
    report "building resources...";
else
    report "running clean-up...";
fi
report " "


createbucketfolder() {
    # creates folder in bucket if it doesn't already exist
    foldertocreate="$*";
    existingobject=$(aws s3api head-object --bucket "$bucketname" --key "$foldertocreate" 2>/dev/null);
    if [ ! "$existingobject" ]; then 
        report "creating folder $foldertocreate in bucket $bucketname";
        runcommand "aws s3api put-object --bucket $bucketname --key $foldertocreate";
    else
        report "found existing folder $foldertocreate in bucket $bucketname, not creating";
    fi;
}

# S3 bucket
existingbucketname=$(aws s3api list-buckets --query "Buckets[?Name=='$bucketname'].Name" --output text 2>/dev/null)

if [ ! $cleanup ]; then
    if [ ! "$existingbucketname" ]; then
        # create S3 Bucket
        report "creating S3 bucket $bucketname"
        if [ "$emitjson" ]; then
            report "bucketwritepolicyjson=$bucketwritepolicyjson";
            report "s3accessidjson=$s3accessidjson";
        fi
        if [ "$aws_region" == "us-east-1" ]; then 
            # if using us-east-1, create-bucket command fails if LocationConstraint is specified!
            bucketregionstring="--region $aws_region";
        else
            bucketregionstring="--region $aws_region --create-bucket-configuration LocationConstraint=$aws_region";
        fi;
        
        runcommand "aws s3api create-bucket --bucket $bucketname $bucketregionstring --acl private";
    else
        report "found existing bucket $existingbucketname, not creating";
    fi;
    
    # block public access for S3 bucket
    existingpolicyattached=$(aws s3api get-public-access-block --bucket "$bucketname" 2>/dev/null | jq -r '.PublicAccessBlockConfiguration | select(.BlockPublicAcls==true) | select(.IgnorePublicAcls==true) | select(.BlockPublicPolicy==true) | select(.RestrictPublicBuckets==true)' 2>/dev/null);
    if [ ! "$existingpolicyattached" ]; then     
        report "attaching public access block policy to bucket $bucketname";
        runcommand "aws s3api put-public-access-block --bucket $bucketname --public-access-block-configuration file://$tempdir/bucketblockpublic.json";
    else
        report "public access block policy already attached to bucket $bucketname, no action taken";
    fi;
    # upload package to initial_version folder in S3 bucket
    if [ "$packagedirectory" ]; then
        report "uploading website files from $packagedirectory to s3://$bucketname/$initial_version/";
        runcommand "aws s3 sync $packagedirectory s3://$bucketname/$initial_version/";
    else
        # create folder in bucket for $initial_version
        createbucketfolder "$initial_version/"    
    fi;
    
    # create website logs for each cloudfront distribution
    for distro in ${cfdistronames//,/ }; do
        foldertocreate="website-logs/$distro/";
        createbucketfolder "$foldertocreate";
    done;
else
    # remove bucket and contents
    if [ "$existingbucketname" ]; then
        report "removing bucket $existingbucketname";
        runcommand "aws s3 rm s3://$existingbucketname --recursive";
        runcommand "aws s3 rb s3://$existingbucketname --force";
    else   
        report "bucket $bucketname doesn't exist, no action taken";
    fi;
fi

# find any existing userID with username $jenkinsbucketwriteuser
existinguserid=$(aws iam get-user --user-name "$jenkinsbucketwriteuser" --query "User.UserName" --output text 2>/dev/null)

if [ "$existinguserid" ]; then 
    # if existing username $jenkinsbucketwriteuser exists:
    
    # check if access keys exist for user
    existingaccesskeyid=$(aws iam list-access-keys --user-name "$jenkinsbucketwriteuser" --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null);
        
    # check if user has the bucketwrite policy attached
    existingattachedpolicyarn=$(aws iam list-attached-user-policies --user-name "$jenkinsbucketwriteuser" --query "AttachedPolicies[?PolicyArn=='$bucketwritepolicyarn'].PolicyArn" --output text 2>/dev/null);
fi

existingpolicyarn=$(aws iam get-policy --policy-arn "$bucketwritepolicyarn" --query "Policy.Arn" --output text 2>/dev/null);

# IAM user creation
if [ ! "$cleanup" ]; then
    if [ ! "$existinguserid" ]; then 
        # create jenkins user for s3 write
        report "creating jenkins bucket write user called $jenkinsbucketwriteuser";
        runcommand "aws iam create-user --user-name $jenkinsbucketwriteuser";
    else
        report "Found existing jenkinsbucketwrite user called $existinguserid, not creating";
    fi
    
    if [ ! "$existingaccesskeyid" ]; then
        # create access-key for jenkins
        report "creating API access key for $jenkinsbucketwriteuser";
        runcommand "aws iam create-access-key --user-name $jenkinsbucketwriteuser";
    else
        report "found existing access key $existingaccesskeyid for user $jenkinsbucketwriteuser, not creating";
    fi

    if [ ! "$existingpolicyarn" ]; then
        # create bucketwrite policy document for jenkinsbucketwriteuser 
        bucketwritepolicyjson=$(echo "$bucketwritepolicytemplate" | jq --arg bucketname "$bucketarn/*" '.Statement[].Resource[]=$bucketname');
        echo "$bucketwritepolicyjson" > $tempdir/bucketwritepolicy.json 
        if [ "$emitjson" ]; then
            report "bucketwritepolicyjson=$bucketwritepolicyjson";
        fi;
        # create bucketwrite policy for jenkinsbucketwriteuser 
        report "creating bucket write policy for $jenkinsbucketwriteuser";
        runcommand "aws iam create-policy --policy-name $bucketwritepolicy --policy-document file://$tempdir/bucketwritepolicy.json";
    else
        report "found existing bucket write policy for $jenkinsbucketwriteuser, not creating";
    fi
        
    if [ ! "$existingattachedpolicyarn" ]; then
        # attach bucketwrite policy to jenkinsbucketwriteuser
        report "attaching policy $bucketwritepolicy at ARN $existingpolicyarn to user $jenkinsbucketwriteuser";
        runcommand "aws iam attach-user-policy --user-name $jenkinsbucketwriteuser --policy-arn $bucketwritepolicyarn";
    else
        report "found bucketwritepolicy $bucketwritepolicy already attached to user $jenkinsbucketwriteuser, no action taken";
    fi
     
else
 
    if [ "$existinguserid" ]; then 
        # if user exists, delete access keys, detach policies and delete user

        if [ "$existingaccesskeyid" ]; then
            # delete access keys for jenkins user
            report "Deleting access key ID $existingaccesskeyid for user $jenkinsbucketwriteuser";
            runcommand "aws iam delete-access-key --access-key-id $existingaccesskeyid --user-name $jenkinsbucketwriteuser";
        else
            report "no access keys found for user $jenkinsbucketwriteuser, no action taken";
        fi;
        
        if [ "$existingattachedpolicyarn" ]; then
            # dettach bucketwrite policy from jenkinsbucketwriteuser if it is attached
            report "detaching policy $bucketwritepolicy at ARN $existingpolicyarn from user $jenkinsbucketwriteuser";
            runcommand "aws iam detach-user-policy --user-name $jenkinsbucketwriteuser --policy-arn $bucketwritepolicyarn";
        else
            report "no bucketwrite policy found attached to user $jenkinsbucketwriteuser, no action taken";
        fi
        
        # delete jenkins user for s3 write
        report "removing jenkins Bucket Write User account $existinguserid";
        runcommand "aws iam delete-user --user-name $existinguserid";
    else
        report "user $jenkinsbucketwriteuser not found, no action taken";
    fi;

    if [ "$existingpolicyarn" ]; then 
        # delete bucketwrite-policy
        report "removing bucket policy $bucketwritepolicy found at ARN $existingpolicyarn";
        runcommand "aws iam delete-policy --policy-arn $existingpolicyarn";
    else
        report "no policy called $bucketwritepolicy found, no action taken";
    fi;
fi


# Get ID of any existing origin access identity
existingoriginaccessid=$(aws cloudfront list-cloud-front-origin-access-identities --query "CloudFrontOriginAccessIdentityList.Items[?Comment=='$bucketname'].Id" --output text 2>/dev/null);

# check if any OAI is already attached to bucket
existingpolicyattached=$(aws s3api get-bucket-policy --bucket "$bucketname" --output json 2>/dev/null);

if [ ! "$cleanup" ]; then
    if [ ! "$existingpolicyattached" ]; then
        # if no existing OAI policy attached, then create and attach one to the bucket
        
            if [ ! "$existingoriginaccessid" ]; then
                # Create Origin Access ID for S3 bucket
                s3accessidjson=$(echo {} | jq --arg bucketname "$bucketname" --arg callerref "$bucketname-$RANDOM" '.CallerReference=$callerref | .Comment=$bucketname')
                echo "$s3accessidjson" > $tempdir/s3accessid.json
                report "creating CloudFront Origin Access Identity for S3 bucket $bucketname";
                runcommand "aws cloudfront create-cloud-front-origin-access-identity  --cloud-front-origin-access-identity-config file://$tempdir/s3accessid.json";
                
                # Get ID of Origin Access Identity
                existingoriginaccessid=$(aws cloudfront list-cloud-front-origin-access-identities --query "CloudFrontOriginAccessIdentityList.Items[?Comment=='$bucketname'].Id" --output text 2>/dev/null);
            else
                report "found existing origin access ID $existingoriginaccessid for bucket $bucketname, not creating";
            fi;

        # Get CanonicalUser of Origin Access Identity
        OAIcanonicaluser=$(aws cloudfront get-cloud-front-origin-access-identity --id "$existingoriginaccessid" --query "CloudFrontOriginAccessIdentity.S3CanonicalUserId" --output text  2>/dev/null);
        OAIarn="arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity $existingoriginaccessid";
        # Create policy document for Origin Access Identity
        bucketOAIaccesspolicyjson="$(echo "$s3grantaccesstemplate" | jq \
        --arg id "$originaccessidentity" \
        --arg canonicaluser "$OAIcanonicaluser" \
        --arg OAIarn "$OAIarn" \
        --arg bucketarn "$bucketarn/*" \
        '.Id = $id |
        .Statement[].Principal.AWS = $OAIarn |
        .Statement[].Resource = $bucketarn'  2>/dev/null)";
        
        # attach policy for Origin Access Identity to bucket
        report "attaching Origin Access Identity policy for $bucketname";
        if [ "$emitjson" ]; then
            report "policy document $bucketOAIaccesspolicyjson";
        fi;
    
        echo "$bucketOAIaccesspolicyjson" > $tempdir/bucketOAIaccesspolicy.json;
        runcommand "aws s3api put-bucket-policy --bucket $bucketname --policy file://$tempdir/bucketOAIaccesspolicy.json";
    else
        report "found existing Origin Access ID  and policy attached to bucket $bucketname, no action taken";
    fi;
fi


route53deleterecord() {
    hostedzoneid="$1";
    dnsrecordname="$2";
    dnsrecordtype="$3";
    dnsrecordvalues="$4";
    report "Deleting records with the following parameters";
    report "hostedzoneid=$hostedzoneid";
    report "dnsrecordname=$dnsrecordname";
    report "dnsrecordtype=$dnsrecordtype";
    report "dnsrecordvalues=$dnsrecordvalues";
    
    r53deleterecordsjson=$(echo "$r53addrecordtemplate" | jq \
                    --arg name "$dnsrecordname" \
                    --arg type "$dnsrecordtype" \
                    '.Changes[].Action="DELETE" |
                    .Changes[].ResourceRecordSet.Name=$name |
                    .Changes[].ResourceRecordSet.Type=$type');
                    
    for value in $dnsrecordvalues; do
        report "removing DNS record $dnsrecordname, type $dnsrecordtype, value $value";
        # modify DNS record JSON, delete all records 
        r53deleterecordsjson=$(echo "$r53deleterecordsjson" | jq --arg value "$value" \
            '.Changes[].ResourceRecordSet.ResourceRecords +=[{"Value":$value}]');
    done;        
    if [ "$emitjson" ]; then
        report "r53deleterecordsjson=$r53deleterecordsjson";
    fi;
    
    # update DNS record JSON with deleted records
    report "deleting DNS $dnsrecordtype record: $dnsrecordname from hosted zone $route53zone";
    
    echo "$r53deleterecordsjson" > $tempdir/r53deleterecords.json
    runcommand "aws route53 change-resource-record-sets --hosted-zone-id $hostedzoneid --change-batch file://$tempdir/r53deleterecords.json";
}

route53addcfrecord() {
    # add a cloudfront record to route53
    dnsrecordname="$1";
    dnsrecordtype="$2";
    dnsrecordcloudfrontdnsname="$3";
    
    report "Adding route53 DNS records with the following parameters:";
    report "    hostedzoneid=$hostedzoneid";
    report "    dnsrecordname=$dnsrecordname";
    report "    dnsrecordtype=$dnsrecordtype";
    report "    dnsrecordcloudfrontdnsname=$dnsrecordcloudfrontdnsname";
   
    parentzone=${dnsrecordname#*.};
    parenthostedzoneid=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='$parentzone.'].Id" --output text);
    if [ ! "$parenthostedzoneid" ]; then
        parentzone=${parentzone#*.};
        parenthostedzoneid=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='$parentzone.'].Id" --output text);
    fi;
                
    r53addcfrecordsjson=$(echo "$r53addrecordtemplate" | jq \
        --arg name "$dnsrecordname" \
        --arg type "$dnsrecordtype" \
        --arg dnsname "$dnsrecordcloudfrontdnsname" \
        '.Changes[].Action="UPSERT" |
        .Changes[].ResourceRecordSet.Name=$name |
        .Changes[].ResourceRecordSet.Type=$type |
        del(.Changes[].ResourceRecordSet.TTL) |
        .Changes[].ResourceRecordSet.AliasTarget.HostedZoneId="Z2FDTNDATAQYW2" |
        .Changes[].ResourceRecordSet.AliasTarget.DNSName=$dnsname |
        .Changes[].ResourceRecordSet.AliasTarget.EvaluateTargetHealth=false
        ');
                    
    if [ "$emitjson" ]; then
        report "r53addcfrecordsjson=$r53addcfrecordsjson";
    fi;
    
    # update DNS record JSON with deleted records
    report "adding DNS $dnsrecordtype record: $dnsrecordname for hosted zone $hostedzoneid";
    
    echo "$r53addcfrecordsjson" > $tempdir/r53addcfrecordsjson.json
    runcommand "aws route53 change-resource-record-sets --hosted-zone-id $parenthostedzoneid --change-batch file://$tempdir/r53addcfrecordsjson.json";
}

# route53
for  route53zone in ${route53zones//,/ }; do

    if nslookup -type=ns "$route53zone" "$publicdns" >/dev/null; then
        report "$route53zone already resolvable on public DNS $publicdns";
        recordresolvable="true";
    else
        report "$route53zone not resolvable on public DNS $publicdns";
        recordresolvable="";
    fi;
    # get id for any existing route53 zone called $route53zone
    existinghostedzoneid=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='$route53zone.'].Id" --output text);
    
    if [ ! "$cleanup" ]; then
        if [ ! "$recordresolvable" ]; then
            if [ ! "$existinghostedzoneid" ]; then
                # create Route53 hosted zone
                report "creating Route53 hosted zone $route53zone";

                runcommand "aws route53 create-hosted-zone --name $route53zone.  --caller-reference $appname-route53-$route53zone-$RANDOM --hosted-zone-config Comment=$appname-route53-$route53zone";
                zonenameservers=$(echo "$output" | jq -r '.DelegationSet.NameServers[]');
                existinghostedzoneid=$(echo "$output" | jq -r '.HostedZone.Id');
            else
                report "existing Route53 hosted zone $route53zone found, no action taken";
                
                #retrieve and check 
                zonenameservers="$(aws route53 list-resource-record-sets --hosted-zone-id $existinghostedzoneid --query "ResourceRecordSets[?Name=='$route53zone.' && Type=='NS'].ResourceRecords[].Value" | jq -r '.[]')";
            fi;
            report "correct NS zone records for domain $route53zone are as follows:";
            report "$zonenameservers";
            
            #extract dots in route53zone
            zonedots="${route53zone//[^.]}";
            #count number of dots (.) to see if a parent zone is required
            zonelevel="${#zonedots}";
            
            #see if parent zone exists
            parentzone="$route53zone";
            foundparenthostedzoneid="";
            while [ "$zonelevel" -gt 1 ]; do
                parentzone=${parentzone#*.};
                zonelevel=$((zonelevel-1));

                echo "checking DNS server $publicdns for parent zone at level $zonelevel: $parentzone";
            
                #find parent 
                parentoriginserver=$(nslookup -type=soa $parentzone $publicdns | grep origin | cut -d'=' -f 2);
                parentoriginserver=${parentoriginserver##*=}; # split at "=" sign
                parentoriginserver="${parentoriginserver#"${parentoriginserver%%[![:space:]]*}"}" # remove leading whitespace
                
                if [ "$parentoriginserver" ]; then 
                    report "found parent DNS server origin $parentoriginserver.  Checking for existing records for $route53zone";

                    # find matching hosted zone ID for parent domain
                    parenthostedzoneid=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='$parentzone.'].Id" --output text 2>/dev/null);
                    
                    if [ ! "$parenthostedzoneid" ]; then
                        report "ERROR: Parent zone $parentzone not found in AWS Account. Automatic NS record registration for zone $route53zone not possible, and certificate will not be auto-approved!";
                        report "NS records in zone $parentzone must be manually created as follows: ";
                        for nsrecord in $zonenameservers; do
                            report "NS: $nsrecord";
                        done;    

                        if [ "${SHLVL}" -gt 1 ] && [ "$exitonerror" ]; then
                            #check SHLLVL to prevent closing bash shell if script is pasted in immediate mode
                            report "script can be re-run (and will continue) when NS records are created.  Exiting...."
                            exit 1;
                        fi;
                        break;
                    else
                        foundparenthostedzoneid="true";
                    fi;
                    
                    # query existing NS record (if any) in $parentzone for $route53zone
                    parentr53zonerecords="$(aws route53 list-resource-record-sets --hosted-zone-id $parenthostedzoneid --query "ResourceRecordSets[?Name=='$route53zone.'].ResourceRecords[].Value" --output json | jq -r '.[]')";
                    
                    if [ "$parentr53zonerecords" ]; then
                        report "found existing NS records in parent zone $parentzone for $route53zone";
                        parentzonepurge="";
                        for nsrecord in $parentr53zonerecords; do
                            if [[ "$zonenameservers" =~ $nsrecord ]]; then
                                report "found existing correct zone record in parent DNS $nsrecord, no action taken";
                            else
                                report "found existing but incorrect zone record $nsrecord in parent DNS";
                                parentzonepurge="true";
                            fi;
                        done;
                        
                        if [ "$parentzonepurge" ]; then
                            purgerecord="";
                            for nsrecord in $parentr53zonerecords; do
                                #create purge record for all incorrect addresses
                                purgerecord=$(echo "$purgerecord"; echo "NS,$route53zone,$nsrecord");
                            done;
                            report "purging existing parent zone records for $route53zone";
                            route53deleterecord "$parenthostedzoneid" "$route53zone" "NS" "$parentr53zonerecords";
                            parentr53zonerecords="";
                        fi;
                    fi;
                    if [ ! "$parentr53zonerecords" ]; then
                        report "creating NS records in parent zone $parentzone for $route53zone";

                        parentchangerecordjson=$(echo $r53addrecordtemplate| jq --arg name "$route53zone." '.Changes[].ResourceRecordSet.Name=$name|.Changes[].ResourceRecordSet.Type="NS"');
                                
                        for nsrecord in $zonenameservers; do
                            # register all zone nameservers in parent domain DNS
                            parentchangerecordjson=$(echo $parentchangerecordjson | jq --arg value "$nsrecord" '.Changes[].ResourceRecordSet.ResourceRecords +=[{"Value":$value}]');
                        done;    
                    
                        if [ "$emitjson" ]; then
                            report "parentchangerecordjson=$parentchangerecordjson";
                        fi;
                        
                        report "adding  to parent zone $parentzone, for $route53zone the following NS records:";
                        report "$zonenameservers";
                            
                        echo "$parentchangerecordjson" > $tempdir/parentchangerecordjson.json
                        runcommand "aws route53 change-resource-record-sets --hosted-zone-id $parenthostedzoneid --change-batch file://$tempdir/parentchangerecordjson.json";
                        
                    fi;
                else
                    if [ "$zonelevel" -gt 1 ]; then
                        report "lookup of parent DNS zone $parentzone failed at level $zonelevel. Trying a level up";
                    else
                        report "ERROR: no parent zone found for $route53zone, cannot auto-register DNS NS records!";
                        break;
                    fi;
                fi;
            if [ "$foundparenthostedzoneid" ]; then
                break;
            fi;
            done;
        else
            report "route53 zone DNS name $route53zone already resolvable, no action taken";
        fi;
    else
        # delete Route53 hosted zone(s) and all records
        
        if [ "$existinghostedzoneid" ]; then
            # cycle through in-scope hosted zones for deletion

            # (re)retrieve zone name from ID
            zone_name=$(aws route53 get-hosted-zone --id "$existinghostedzoneid" --query "HostedZone.Name" --output text 2>/dev/null)
            
            # find recordssets to delete, comma delimited as Value,DNSName,Type
            r53recordsets=$(aws route53 list-resource-record-sets --hosted-zone-id "$existinghostedzoneid" | jq -r -c '.ResourceRecordSets[] |  select(.Type=="A" or .Type=="CNAME") | .ResourceRecords[].Value as $Value | {Name,Type,$Value} | join(",")');
            
            #report "found route53 recordssets $r53recordsets";

            # cycle through all in-scope records in zone for deletion
            for resourcerecordset in $r53recordsets; do
                dnsrecordname=$(echo "$resourcerecordset" | cut -d, -f1);
                dnsrecordtype=$(echo "$resourcerecordset" | cut -d, -f2);
                dnsrecordvalue=$(echo "$resourcerecordset" | cut -d, -f3);
                report "removing DNS record $dnsrecordname, type $dnsrecordtype, value $dnsrecordvalue";
                route53deleterecord "$existinghostedzoneid" "$dnsrecordname" "dnsrecordtype" "$dnsrecordvalue";
            done;
            
            # retrieve zone name
            zone_name=$(aws route53 get-hosted-zone --id "$existinghostedzoneid" --query "HostedZone.Name" --output text 2>/dev/null);
            
            # remove hosted zone
            report "deleting route53 hosted zone name $zone_name, ID $existinghostedzoneid";
            runcommand "aws route53 delete-hosted-zone --id $existinghostedzoneid";
        else
            report "no hosted zone for $route53zone found, no action taken";
        fi;
    fi;
done


# certificate
if [ "$certname" ]; then
    existingcertarn=$(aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[?DomainName=='$certname'].CertificateArn" --output text 2>/dev/null)
    if [ ! "$cleanup" ]; then
        # create certificate
        if [ ! "$existingcertarn" ]; then
            if [ "$certsans" ]; then
                # if subject-alternate-names are provided, add to cert request command
                sanscommand=" --subject-alternative-names $certsans";
            fi;
            report "creating certificate request for $certname, $sanscommand";
            

            # must use us-east-1 region in order for certificate to work with CloudFront
           
            runcommand "aws acm request-certificate --region us-east-1 --domain-name $certname $sanscommand --validation-method DNS";
            
            #get ARN of certificate from output
            certarn=$(echo "$output" | jq -r '.CertificateArn');
            report "certarn=$certarn"
        else
            report "existing certificate $certname with ARN $existingcertarn found, not creating";
            certarn="$existingcertarn";
        fi;
        
        #check if certificate is issued.  Will be pending if DNS is not set up correctly
        certificatestatus=$(aws acm describe-certificate --region us-east-1 --certificate-arn $certarn --query "Certificate.Status" --output text 2>/dev/null)
        
        if [[ ! "$certificatestatus" == "ISSUED" ]]; then
            
            report "certificate not issued yet, status is $certificatestatus";
            
            fullcertjson=$(aws acm describe-certificate --region us-east-1 --certificate-arn "$certarn" --output json);
            if [ "$emitjson" ]; then
                report "fullcertjson=$fullcertjson";
            fi;
            
            pathstovalidate=$(echo "$fullcertjson" | jq -r '.Certificate.DomainValidationOptions[]|select(.ValidationStatus="PENDING_VALIDATION").DomainName' 2>/dev/null)
            
            for path in $pathstovalidate; do
                certvalidationname=$(echo "$fullcertjson" | jq --arg path "$path" -r '.Certificate.DomainValidationOptions[]|select(.DomainName==$path).ResourceRecord.Name');

                
                
                certvalidationvalue=$(echo "$fullcertjson" | jq --arg path "$path" -r '.Certificate.DomainValidationOptions[]|select(.DomainName==$path).ResourceRecord.Value');
                
                certvalidationtype=$(echo "$fullcertjson" | jq --arg path "$path" -r '.Certificate.DomainValidationOptions[]|select(.DomainName==$path).ResourceRecord.Type');
               
                if nslookup -type="$certvalidationtype" "$certvalidationname" "$publicdns" >/dev/null; then
                    report "certificate validation address $certvalidationname, type $certvalidationtype already publicly resolvable"
                fi;
                
                parentzone=${certvalidationname#*.};
                parenthostedzoneid=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='$parentzone'].Id" --output text);
                if [ ! "$parenthostedzoneid" ]; then
                    parentzone=${parentzone#*.};
                    parenthostedzoneid=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='$parentzone'].Id" --output text);
                fi;
                
                existingrecordqueryresponse=$(aws route53 test-dns-answer --hosted-zone-id $parenthostedzoneid --record-name $certvalidationname --record-type $certvalidationtype --query "ResponseCode" --output text 2>/dev/null);
                
                if [[ ! "$existingrecordqueryresponse" == "NOERROR" ]]; then 
                    report "creating DNS record $certvalidationname of type $certvalidationtype with value $certvalidationvalue in $parentzone, host ID $parenthostedzoneid for certificate auto-validation";
                    
                    # update DNS with certificate validation records
                    certvalidationdnsrecordjson=$(echo "$r53addrecordtemplate" | jq --arg name "$certvalidationname" --arg value "$certvalidationvalue" --arg type "$certvalidationtype" '.Changes[].ResourceRecordSet.Name=$name | .Changes[].ResourceRecordSet.Type=$type| .Changes[].ResourceRecordSet.ResourceRecords=[{"Value":$value}]');
                
                    if [ "$emitjson" ]; then 
                        report "certvalidationdnsrecordjson=$certvalidationdnsrecordjson";
                    fi;
                               
                    echo "$certvalidationdnsrecordjson" >$tempdir/certvalidationdnsrecord.json;
                    # set DNS recordset for certificate validation
                    runcommand "aws route53 change-resource-record-sets --hosted-zone-id $parenthostedzoneid --change-batch file://$tempdir/certvalidationdnsrecord.json";
                else
                    report "found existing DNS entry $certvalidationname for certificate auto-validation, no action taken";
                fi;

            done;
        else
            report "certificate is already issued, no validation action taken";
        fi;
    else
        if [ "$existingcertarn" ]; then 
            report "deleting existing certificate $certname";
            runcommand "aws acm delete-certificate --region us-east-1 --certificate-arn $existingcertarn";
        else
            report "no certificate with name $certname exists, no action taken";
        fi;
    fi;
fi

existinghostedzoneid=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='$route53zone.'].Id" --output text);


if [ "$certname" ] && [ "$produrl" ] && [ "$testurl" ] && [ ! "$cleanup" ]; then 
    certificatestatus=$(aws acm describe-certificate --region us-east-1 --certificate-arn $certarn --query "Certificate.Status" --output text 2>/dev/null)
    if [ "$certificatestatus" != "ISSUED" ]; then
        report "certificate status is $certificatestatus.  Waiting till it is issued before attaching to CloudFront distributions"
    fi;
    while [ "$certificatestatus" != "ISSUED" ]; do
        report "waiting for certificate issue, retry in $waitperiod seconds..."
        certificatestatus=$(aws acm describe-certificate --region us-east-1 --certificate-arn $certarn --query "Certificate.Status" --output text 2>/dev/null)
        
        sleep $waitperiod;
    done;
fi

# cloudfront
if [ "$emitjson" ]; then
    cfqueryparameters="--output json";
else
    cfqueryparameters="--query 'Distribution.DomainName' --output text";
fi;

if [ ! "$cleanup" ]; then
    for distro in ${cfdistronames//,/ }; do
        distroname="$appname-cloudfront-$distro";
        report "distroname=$distroname";
        cfaliasid="";
        if [ "$distro" == "blue" ] && [ "$produrl" ]; then 
            cfaliases=1;
            cfaliasid="$produrl";
        fi;
        if [ "$distro" == "test" ] && [ "$testurl" ]; then 
            cfaliases=1;
            cfaliasid="$produrl";
        fi;
        
        # check if distro already exists
        existingdistroID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$distroname'].Id" --output text 2>/dev/null);
        
        if [ ! "$existingdistroID" ]; then
            
            # Create Cloudfront Test Distribution Parameters
            OAI=$(aws cloudfront list-cloud-front-origin-access-identities --query "CloudFrontOriginAccessIdentityList.Items[?Comment=='$bucketname'].Id" --output text 2>/dev/null);
            
            distroparams=$(echo "$cfdistroconfigtemplate" | jq \
            --arg callerreference "create-$distroname-$RANDOM" \
            --arg originid "$bucketname-${initial_version//./-}" \
            --arg bucketaddress "$bucketaddress" \
            --arg comment "$distroname" \
            --arg OAI "origin-access-identity/cloudfront/$OAI" \
            --arg realeasefolder "/$initial_version" \
            --arg loggingfolder "/website-logs/$distro" \
            '.CallerReference = $callerreference |
            .Origins.Items[].Id = $originid | 
            .Origins.Items[].DomainName = $bucketaddress | 
            .Origins.Items[].OriginPath = $realeasefolder | 
            .Origins.Items[].S3OriginConfig.OriginAccessIdentity = $OAI | 
            .DefaultCacheBehavior.TargetOriginId =$originid |
            .Comment = $comment |
            .Logging.Bucket = $bucketaddress | 
            .Logging.Prefix = $loggingfolder');
            if [ "$emitjson" ]; then
                report "distroparams=$distroparams";
            fi;

            if [ "$cfaliasid" ]; then 
                # add website alias
                report "adding url $cfaliasid"
                # we need $certarn!
                distroparams=$(echo "$distroparams" | jq \
                --arg aliases "$cfaliases" \
                --arg certarn "$certarn" \
                --arg aliasid "$cfaliasid" \
                '.Aliases.Quantity = 1 |
                .Aliases.Items += [$aliasid] |
                del(.ViewerCertificate.CloudFrontDefaultCertificate) |
                .ViewerCertificate.ACMCertificateArn = $certarn |
                .ViewerCertificate.SSLSupportMethod = "sni-only"');
            fi;

            # Create CloudFront Distribution
            if [ "$emitjson" ]; then
                report "For $distroname, distroparams=$distroparams";
            fi;
            echo "$distroparams" > $tempdir/distroparams-$distro.json
  
            runcommand "aws cloudfront create-distribution --distribution-config file://$tempdir/distroparams-$distro.json $cfqueryparameters";

        else
            report "existing cloudfront distribution for $distroname with id $existingdistroID exists, not creating";
        fi;
        cfdnsname=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$distroname'].DomainName" --output text 2>/dev/null);
        if [ "$cfaliasid" ]; then 
            if nslookup -type=a "$cfaliasid" "$publicdns" >/dev/null; then
                report "URL $cfaliasid is already resolvable, no action taken";
            else
                report "URL $cfaliasid not resolvable, adding to DNS";
                # add website alias to DNS
                route53addcfrecord "$cfaliasid" "A" "$cfdnsname";
            fi;
        fi;
               
    done;
else
    for distro in ${cfdistronames//,/ }; do
        # find IDs of existing cloudfront distros for shutdown 
        # shutdown takes time so this script will shut down every distribution first before deleting (saves time)
        distroname="$appname-cloudfront-$distro";
                
        # find ID of distro to shut down
        existingdistroID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$distroname'].Id" --output text 2>/dev/null);
        if [ "$existingdistroID" ]; then
            for cfid in $existingdistroID; do
                report "found cloudfront ID $cfid for shutdown";
                
                #find current etag (required to execute change)
                ETAG=$(aws cloudfront get-distribution-config --id "$cfid" --query "ETag" --output text 2>/dev/null);
                report "ETAG=$ETAG";
                # get current config json
                cfcurrentconfig=$(aws cloudfront get-distribution-config --id "$cfid" --query "DistributionConfig" --output json 2>/dev/null);
                
                # create new disabled config json                
                if [ "$(echo "$cfcurrentconfig" | jq '.Enabled')" = "true" ]; then
                    disableconfig=$(echo "$cfcurrentconfig" | jq '.Enabled = false');
                    echo "$disableconfig" > $tempdir/disableconfig.json
                    
                    # update distro config to disabled
                    report "disabling cloudfront distribution $distroname with ID $cfid and ETag $ETAG";
                    runcommand "aws cloudfront update-distribution --id $cfid --if-match $ETAG --distribution-config file://$tempdir/disableconfig.json $cfqueryparameters";
                else
                    report "found existing disabled cloudfront distribution $distroname with ID $cfid, no action taken";
                fi;
            done;
        else
            report "no cloudfront distribution called $distroname found, nothing to shutdown";
        fi;
    done;
    for distro in ${cfdistronames//,/ }; do
        # find IDs of existing cloudfront distros for deletion
        distroname="$appname-cloudfront-$distro";
        
        # find ID of distro to delete
        existingdistroID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$distroname'].Id" --output text 2>/dev/null);
        
        if [ "$existingdistroID" ]; then
            for cfid in $existingdistroID; do
                report "Found cloudfront ID $cfid for deletion";
                #find current etag (required to execute change)
                ETAG=$(aws cloudfront get-distribution-config --id "$cfid" --query "ETag" --output text 2>/dev/null);
                report "ETAG=$ETAG";
                 while true; do
                    # wait for distribution to be disabled (can take a few minutes)
                    cfstatus=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$distroname'].Status" --output text 2>/dev/null);

                    if [ "$cfstatus" == "InProgress" ]; then
                        report "status $cfstatus, waiting for completion, retry in $waitperiod seconds...";
                    else 
                        report "status $cfstatus";
                        break;
                    fi;
                    sleep $waitperiod;
                done;
                
                # delete distribution
                report "deleteing cloudfront distribution $distroname with ID $cfid and ETag $ETAG";
                runcommand "aws cloudfront delete-distribution --id $cfid --if-match $ETAG";
            done;
        else
            report "no cloudfront distribution called $distroname found, nothing to delete";
        fi;
    done;
        
    # cleanup origin-access-identity

    if [ "$existingoriginaccessid" ]; then 
        #find current etag (required to execute change)
        ETAG=$(aws cloudfront get-cloud-front-origin-access-identity --id "$existingoriginaccessid" --query "ETag" --output text 2>/dev/null);
        
        # delete cloudfront origin access identity
        report "deleting CloudFront Origin Access Identity for S3 bucket $bucketname";
        runcommand "aws cloudfront delete-cloud-front-origin-access-identity --id $existingoriginaccessid --if-match $ETAG";
    else
        report "no origin access id for bucket $bucketname found, no action taken";
    fi
fi

if [ "$produrl" ] && [ "$route53zones" ] && [ "$certname" ] && [ "$certsans" ]; then
    report "prod website should be available at https://$produrl"
fi;

if [ "$testurl" ] && [ "$route53zones" ] && [ "$certname" ] && [ "$certsans" ]; then
    report "test website should be available at https://$testurl"
fi;
