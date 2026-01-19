#!/bin/bash

curl -L -o apkmd https://github.com/tanishqmanuja/apkmirror-downloader/releases/download/v2.0.8/apkmd
curl -L -o apkcd https://github.com/nirewen/apkcombo-downloader/releases/download/v1.0.3/apkcd-bun-linux-x64
chmod +x apkmd apkcd
if [ "$1" == "apkmirror" ]; then
    ./apkmd "$2" "$3"
elif [ "$1" == "apkcombo" ]; then
    ./apkcd "$4" "$5"
else
    echo "Usage: $0 {apkmirror|apkcombo} <app-identifier> <output-file>"
    exit 1
fi