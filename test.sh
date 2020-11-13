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


for i in "$@"
do
	case $i in
		-ak=*|--aws-access-key=*)
		aws_access_key="${i#*=}"
		export AWS_ACCESS_KEY=$aws_access_key
		shift # past argument=value
		;;
		-as=*|--aws-secret=*)
		aws_secret="${i#*=}"
		export AWS_SECRET_ACCESS_KEY=$aws_secret
		shift # past argument=value
		;;
		-ar=*|--aws-region=*)
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
		-c=*|--country-id=*)
		country_id="${i#*=}"
		shift # past argument=value
		;;
		-i=*|--instance-name=*)
		instance_name="${i#*=}"
		shift # past argument with no value
		;;
		-v=*|--initial-version=*)
		initial_version="${i#*=}"
		shift # past argument with no value
		;;
		-l=*|--logpath=*)
		logpath="${i#*=}"
		shift # past argument with no value
		;;
		-s=*|--silent=*)
		silent=true
		shift # past argument with no value
		;;
		*)
			  # unknown option
		;;
	esac
done