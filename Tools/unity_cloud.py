"""Unity Build Automation v2: probe, configure one target, and trigger one build.

Authentication is read only from runtime environment variables. Output is an
allowlist of safe fields, never a dump of settings, credentials, or build logs.
Reference: https://docs.unity.com/en-us/oas-build-automation-client/2.0.0
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, build_opener, HTTPRedirectHandler

BASE = "https://build-automation.services.api.unity.com/v2"

class CloudError(Exception):
    def __init__(self, report):
        super().__init__(report["code"])
        self.report = report

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward an Authorization header to another endpoint.

def segment(value):
    if not value or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise CloudError({"code":"INVALID_RESOURCE_ID"})
    return quote(value, safe="")

class Client:
    def __init__(self, env=None):
        self.env = os.environ if env is None else env
        key = self.env.get("UNITY_SERVICE_ACCOUNT_KEY_ID", "")
        secret = self.env.get("UNITY_SERVICE_ACCOUNT_SECRET_KEY", "")
        bearer = self.env.get("UNITY_BEARER_TOKEN", "")
        self.secrets = [x for x in (key, secret, bearer) if x]
        if key and secret:
            encoded = base64.b64encode((key+":"+secret).encode()).decode()
            self.auth = "Basic " + encoded
            self.secrets.extend([encoded, self.auth])
        elif bearer:
            self.auth = "Bearer " + bearer
            self.secrets.append(self.auth)
        else:
            raise CloudError({"code":"AUTH_UNAVAILABLE", "required_environment":["UNITY_SERVICE_ACCOUNT_KEY_ID","UNITY_SERVICE_ACCOUNT_SECRET_KEY"], "requests_sent":0})
        self.org = segment(self.env.get("UNITY_ORG_ID", "2476061786756"))
        self.opener = build_opener(NoRedirect())

    def redact(self, value):
        if isinstance(value, dict):
            return {k:self.redact(v) for k,v in value.items()}
        if isinstance(value, list):
            return [self.redact(v) for v in value]
        if isinstance(value, str):
            for secret in sorted(self.secrets,key=len,reverse=True):
                value = value.replace(secret,"[REDACTED]")
        return value

    def call(self, path, method="GET", payload=None):
        request = Request(BASE+path, data=None if payload is None else json.dumps(payload).encode(),
            headers={"Authorization":self.auth,"Accept":"application/json","Content-Type":"application/json"}, method=method)
        try:
            with self.opener.open(request, timeout=30) as response:
                raw=response.read(16*1024*1024)
                return json.loads(raw) if raw else None
        except HTTPError as error:
            try: body=json.loads(error.read(65536))
            except (ValueError, UnicodeError): body={}
            report={"code":"UNITY_HTTP_ERROR","status":error.code,"method":method,"endpoint":path,
                "request_id":body.get("requestId",error.headers.get("X-Request-ID",""))}
            for field in ("title","detail","code","details"):
                if field in body:report["unity_"+field]=body[field]
            if error.code==403:report["permission_note"]="Only the server-reported permission is evidence; no role or permission is inferred."
            raise CloudError(self.redact(report)) from None
        except (URLError, TimeoutError, ValueError):
            raise CloudError({"code":"UNITY_TRANSPORT_OR_RESPONSE_ERROR","method":method,"endpoint":path}) from None

    def project(self):
        projects=self.call("/orgs/"+self.org+"/projects?include=serviceFlags")
        if not isinstance(projects,list):raise CloudError({"code":"UNITY_PROJECT_RESPONSE_SHAPE"})
        project_id=self.env.get("UNITY_PROJECT_ID","")
        name=self.env.get("UNITY_PROJECT_NAME","Yardman")
        matches=[p for p in projects if (p.get("projectid")==project_id if project_id else p.get("name")==name)]
        if len(matches)!=1:raise CloudError({"code":"CANONICAL_PROJECT_NOT_UNIQUE_OR_NOT_VISIBLE","project_name":name,"matches":len(matches)})
        project=matches[0]
        if project.get("name")!=name:raise CloudError({"code":"CANONICAL_PROJECT_NAME_MISMATCH"})
        self.root="/orgs/"+self.org+"/projects/"+segment(project.get("projectid"))
        return {k:project[k] for k in ("projectid","name","disabled") if k in project}

    def targets(self):
        result=[]
        for offset in range(0,10000,100):
            page=self.call(self.root+"/buildtargets?limit=100&offset="+str(offset))
            if not isinstance(page,list):raise CloudError({"code":"UNITY_TARGET_RESPONSE_SHAPE"})
            result.extend(page)
            if len(page)<100:return result
        raise CloudError({"code":"UNITY_TARGET_PAGINATION_LIMIT"})

def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument("command",choices=["probe","configure","build"],nargs="?",default="probe")
    parser.add_argument("--config",default=str(Path(__file__).resolve().parent.parent/"Cloud/android-proof-target.json"))
    parser.add_argument("--target-id")
    parser.add_argument("--commit",help="Exact 40-character Git commit required for build")
    args=parser.parse_args(argv)
    client=None
    try:
        client=Client();project=client.project();targets=client.targets()
        versions=client.call(client.root+"/versions/unity?platform=android")
        if not isinstance(versions,list):raise CloudError({"code":"UNITY_VERSION_RESPONSE_SHAPE"})
        report={"result":"READ_ACCESS_CONFIRMED","project":project,
            "build_targets":[{k:t[k] for k in ("buildtargetid","name","platform","enabled") if k in t} for t in targets],
            "android_unity_versions":[{k:v[k] for k in ("name","value","deprecated","hidden","architectures","entitledPlatformsSupported") if k in v} for v in versions],
            "write_access":"UNTESTED"}
        if args.command=="configure":
            config=json.loads(Path(args.config).read_text())
            requested=config["settings"]["unityVersion"]
            supported=[v for v in versions if str(v.get("value","")).replace("_",".")==requested and not v.get("deprecated") and not v.get("hidden")]
            if len(supported)!=1:raise CloudError({"code":"ENGINE_NOT_CONFIRMED_AVAILABLE","requested_version":requested})
            config["settings"]["unityVersion"]=supported[0]["value"]
            existing=[t for t in targets if t.get("name")==config["name"]]
            if existing:raise CloudError({"code":"TARGET_ALREADY_EXISTS_REVIEW_BEFORE_UPDATE","target_ids":[t.get("buildtargetid") for t in existing]})
            created=client.call(client.root+"/buildtargets","POST",config)
            report={"result":"TARGET_CREATED","target":{k:created[k] for k in ("buildtargetid","name","platform") if k in created}}
        elif args.command=="build":
            if not re.fullmatch(r"[0-9a-f]{40}",args.commit or ""):raise CloudError({"code":"EXACT_COMMIT_REQUIRED"})
            target=[t for t in targets if t.get("buildtargetid")==args.target_id]
            if len(target)!=1 or target[0].get("platform")!="android":raise CloudError({"code":"ANDROID_TARGET_NOT_FOUND"})
            builds=client.call(client.root+"/buildtargets/"+segment(args.target_id)+"/builds","POST",{"clean":True,"commit":args.commit,"label":"ARCH-PROOF-001"})
            report={"result":"BUILD_REQUEST_ACCEPTED","builds":[{k:b[k] for k in ("build","buildtargetid","buildStatus","error") if k in b} for b in builds]}
        print(json.dumps(client.redact(report),indent=2));return 0
    except CloudError as error:
        print(json.dumps(error.report,indent=2));return 2
    except (OSError,KeyError,TypeError,ValueError):
        print(json.dumps({"code":"CLOUD_CONFIG_OR_RESPONSE_INVALID"}));return 3

if __name__=="__main__":sys.exit(main())
