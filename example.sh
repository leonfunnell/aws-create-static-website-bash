./aws-create-static-website-bash.sh -l=log /
              --application-name=cweb /
	      --environment-name=dev /
	      --country=uk /
	      -rz=cweb.cwebffhjk.mooo.com /
	      -pu=live.cweb.cwebffhjk.mooo.com /
	      -tu=test.cweb.cwebffhjk.mooo.com /
	      -cert=*.cweb.cwebffhjk.mooo.com /
	      -certsans="*.live.cweb.cwebffhjk.mooo.com,*.test.cweb.cwebffhjk.mooo.com" /
	      -p=../../../cweb/cweb-1.16/
