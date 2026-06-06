#!/bin/bash
# Fetch web content using Jina AI Reader API
URL=$1
if [ -z "$URL" ]; then
  echo "Usage: ./fetch_jina.sh <URL>"
  exit 1
fi

curl -s "https://r.jina.ai/$URL" \
  -H "Authorization: Bearer jina_9042bc5997e745f993e911ad1461ad3c8hfFdHjAQXkVAYH5O_sjngQ_2I4G"
