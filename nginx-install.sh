#!/bin/bash
sudo apt-get update
echo "installing nginx webserver"
sudo apt-get install nginx -y
sudo service nginx restart
