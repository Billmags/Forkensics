#!/usr/bin/env bash
# Temporary runner — fill in your credentials from 1Password, then run this file.
# Delete this file after the test completes.

R2_ENDPOINT='https://1dd6ede816fa36a5a824a6e21f82ad7b.r2.cloudflarestorage.com'
R2_ACCESS_KEY_ID='a49b26d21c3bb73d28c448c2e35db336b58aec820404526d76a2862a866db7be'
R2_SECRET_ACCESS_KEY='a49b26d21c3bb73d28c448c2e35db336b58aec820404526d76a2862a866db7be'
DB_URL='postgresql://supabase_admin:postgres@127.0.0.1:54322/postgres'

export R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY DB_URL

bash tools/integration-runner.sh




export R2_ENDPOINT='https://1dd6ede816fa36a5a824a6e21f82ad7b.r2.cloudflarestorage.com'
export R2_ACCESS_KEY_ID='a49b26d21c3bb73d28c448c2e35db336b58aec820404526d76a2862a866db7be'
export R2_SECRET_ACCESS_KEY='a49b26d21c3bb73d28c448c2e35db336b58aec820404526d76a2862a866db7be'
export R2_BUCKET="forkensics-dev-media"
bash tools/integration-runner.sh



export R2_ACCESS_KEY_ID="<32-char value from Cloudflare>"
export R2_SECRET_ACCESS_KEY="<64-char value — you probably have this right>"
bash tools/integration-runner.sh


cd ~/Desktop/WhatAndWhere && bash -c 'printf "DB password: " && read -s PASS && echo && supabase db push --db-url "postgresql://postgres.hkfrbdpedrxmbsawnbpr:${PASS}@aws-0-us-east-1.pooler.supabase.com:5432/postgres"'





supabase migration list --db-url "postgresql://postgres.Bruinsclassic2010!:PASSWORD@aws-0-us-east-1.pooler.supabase.com:6543/postgres"




supabase migration list --db-url "postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres"


supabase migration list --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres'


_________________________________________________________________________________________

supabase migration repair --status reverted --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260817221919


supabase migration repair --status reverted --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260817222031


supabase migration repair --status reverted --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260817222602

supabase migration repair --status reverted --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260817222951

supabase migration repair --status reverted --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260817230038

supabase migration repair --status reverted --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260817231020

supabase migration repair --status reverted --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260817231738

supabase migration repair --status applied --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260807000004

supabase migration repair --status applied --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres' 20260807000005

supabase db push --dry-run --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres'

supabase db push --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres'

supabase migration list --db-url 'postgresql://postgres.hkfrbdpedrxmbsawnbpr:Bruinsclassic2010!@aws-0-us-east-1.pooler.supabase.com:6543/postgres'