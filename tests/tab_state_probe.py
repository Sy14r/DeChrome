#!/usr/bin/env python3
"""Read synthetic tab fixtures from a running DeChrome QA profile.

Developer-only: requires the websockets package, never shipped in DeChrome.app.
"""
import argparse
import json
from pathlib import Path
import urllib.request
from websockets.sync.client import connect


def rpc(url, method, params=None):
    with connect(url, origin=None, proxy=None, open_timeout=4, close_timeout=1) as socket:
        socket.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        while True:
            reply = json.loads(socket.recv(timeout=5))
            if reply.get("id") != 1:
                continue
            if "error" in reply:
                raise RuntimeError(reply["error"])
            return reply.get("result", {})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    args = parser.parse_args()
    lines = (args.profile / "DevToolsActivePort").read_text().splitlines()
    port = int(lines[0])
    assert 0 < port < 65536 and lines[1].startswith("/devtools/browser/")
    browser = f"ws://127.0.0.1:{port}{lines[1]}"
    tabs = rpc(browser, "Target.getTargets", {"filter": [{"type": "tab", "exclude": False}, {"exclude": True}]})["targetInfos"]
    tab_metadata = []
    for tab in tabs:
        window = rpc(browser, "Browser.getWindowForTarget", {"targetId": tab["targetId"]})
        tab_metadata.append({"id": tab["targetId"], "title": tab["title"], "url": tab["url"],
                             "windowId": window["windowId"], "bounds": window["bounds"], **tab.get("embedderData", {})})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"http://127.0.0.1:{port}/json/list", timeout=4) as response:
        pages = json.load(response)
    fixtures = []
    for page in pages:
        if page.get("type") != "page" or "/fixtures/tabs.html" not in page.get("url", ""):
            continue
        # Construct the local URL ourselves, rather than trusting endpoint hosts.
        endpoint = f"ws://127.0.0.1:{port}/devtools/page/{page['id']}"
        result = rpc(endpoint, "Runtime.evaluate", {"expression": "JSON.stringify({url:location.href,label:document.querySelector('#identity')?.textContent,draft:document.querySelector('#draft')?.value,counter:document.querySelector('#counter')?.textContent,activeElement:document.activeElement?.id||document.activeElement?.tagName,viewport:{width:innerWidth,height:innerHeight}})", "returnByValue": True})
        if "exceptionDetails" in result:
            raise RuntimeError(result["exceptionDetails"])
        fixtures.append(json.loads(result["result"]["value"]))
    print(json.dumps({"tabs": tab_metadata, "fixtures": fixtures}, indent=2))


if __name__ == "__main__":
    main()
