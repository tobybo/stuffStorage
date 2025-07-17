import requests
import json
import sys
import re

def main():

    url = "https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id={}&client_secret={}".format(sys.argv[1], sys.argv[2])

    payload = ""
    headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
    }

    response = requests.request("POST", url, headers=headers, data=payload)

    match = re.search(r'"access_token":"(.*?)"', response.text)
    if match:
        access_token = match.group(1)
        print(access_token)

if __name__ == '__main__':
    main()

