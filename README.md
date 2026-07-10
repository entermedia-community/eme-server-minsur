# eme-server-minsur


How to clone eMe testu-server into a running eme-lib instance.



cd testu-clientname/

#Save git credentials
git config --global credential.helper store

git init
git remote add origin https://github.com/entermedia-community/eme-server-minsur.git
git fetch
git reset --hard origin/main
git branch --set-upstream-to=origin/main master
git pull
