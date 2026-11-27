"""Run real CLI and private-network HTTP checks with synthetic data and owned containers."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid


HTTP_CLIENT = r'''
import hashlib,http.client,json,sys,time
host=sys.argv[1]; expected=sys.argv[2]; purpose=sys.argv[3]; raw=sys.stdin.buffer.read()
response_fixture=bytes.fromhex(sys.argv[4]) if len(sys.argv)>4 else b''
for attempt in range(90):
    try:
        connection=http.client.HTTPConnection(host,8080,timeout=2)
        connection.request('GET','/health'); response=connection.getresponse(); response.read()
        if response.status==200: break
    except OSError: pass
    finally:
        connection.close()
    time.sleep(1)
else: raise RuntimeError('worker did not become ready')
def post(route,payload):
    connection=http.client.HTTPConnection(host,8080,timeout=130)
    connection.request('POST',route,body=payload,headers={'Content-Type':'application/fhir+json'})
    response=connection.getresponse(); data=response.read(262145); connection.close()
    return response.status,data
def check(payload,status,code=None):
    http_status,data=post('/validate',payload)
    assert http_status==status,(http_status,data)
    assert len(data)<=2048
    value=json.loads(data)
    assert value['sha256']==hashlib.sha256(payload).hexdigest()
    assert value['validatorIdentity']==expected
    assert value['valid']==(status==200)
    assert value.get('code')==code
    assert 'purpose' not in value and 'diagnostics' not in value
    print(json.dumps({'httpStatus':status,'code':code,'sha256':value['sha256']}),flush=True)
def authoring(route,payload,status,rule=None):
    http_status,data=post(route,payload)
    assert http_status=={'valid':200,'unavailable':503}.get(status,422),(http_status,data[:2048])
    assert len(data)<=262144
    value=json.loads(data)
    assert value['sha256']==hashlib.sha256(payload).hexdigest()
    assert value['validatorIdentity']==expected
    assert value['purpose']==route.rsplit('/',1)[1]
    assert value['status']==status,(value['status'],value['diagnostics'][:5])
    assert (status=='invalid')==any(item['severity']=='error' for item in value['diagnostics'])
    assert rule is None or any(item['rule']==rule for item in value['diagnostics']),value['diagnostics'][:5]
    print(json.dumps({'route':route,'status':status,'findings':len(value['diagnostics']),'sha256':value['sha256']}),flush=True)
def pair(questionnaire,response):
    return b'{"resourceType":"Bundle","type":"collection","entry":[{"resource":'+questionnaire+b'},{"resource":'+response+b'}]}'
if purpose=='questionnaire':
    route='/validate/questionnaire'
    authoring(route,raw,'valid')
    authoring(route,b'{"x":1,"x":2}','invalid','invalid-json')
    resource=json.loads(raw); del resource['status']
    authoring(route,json.dumps(resource,separators=(',',':')).encode(),'invalid')
    authoring(route,raw,'valid')
    if response_fixture:
        authoring('/validate/questionnaire-response',pair(raw,response_fixture),'valid')
        answers=json.loads(response_fixture)
        questionnaire=json.loads(raw)
        answers['questionnaire']=questionnaire['url']+'|999.0.0'
        authoring('/validate/questionnaire-response',pair(raw,json.dumps(answers).encode()),'incomplete','Questionnaire_QR_Q_NotFound')
        structure='/validate/questionnaire-response-structure'
        for payload,status,code in ((response_fixture,200,None),(b'{"x":1,"x":2}',422,'invalid_json')):
            http_status,data=post(structure,payload)
            value=json.loads(data)
            assert (http_status,value['valid'],value.get('code'),value['purpose'])==(status,status==200,code,'questionnaire-response-structure'),value
            assert value['sha256']==hashlib.sha256(payload).hexdigest() and value['validatorIdentity']==expected and len(data)<=2048
            print(json.dumps({'route':structure,'httpStatus':http_status,'sha256':value['sha256']}),flush=True)
    authoring('/validate/questionnaire-response',b'{"resourceType":"Bundle"}','invalid','pair-input')
    connection=http.client.HTTPConnection(host,8080,timeout=10)
    connection.request('GET','/health'); response=connection.getresponse(); response.read(); connection.close()
    assert response.status==200,('engine not restarted after a pair',response.status)
else:
    check(raw,200)
    check(b'{"x":1,"x":2}',422,'invalid_json')
    resource=json.loads(raw)
    observation=next(entry['resource'] for entry in resource['entry'] if entry['resource']['resourceType']=='Observation')
    del observation['status']
    check(json.dumps(resource,separators=(',',':')).encode(),422,'invalid_fhir')
    check(raw,200)
for path in ('/loadIG','/stop','/validateResource','/validate?profile=untrusted','/validate/questionnaire?profile=untrusted'):
    connection=http.client.HTTPConnection(host,8080,timeout=10)
    connection.request('POST',path,body=raw,headers={'Content-Type':'application/fhir+json'})
    response=connection.getresponse(); data=response.read(2049); connection.close()
    assert response.status==400,(path,response.status)
    assert json.loads(data)=={'code':'invalid_request'}
if purpose=='questionnaire':
    authoring('/validate/questionnaire',raw,'valid')
else:
    check(raw,200)
'''


RECOVERY_CLIENT = r'''
import json,os,signal,sys
sys.path.insert(0,'/opt/validator')
import worker
signal.signal(signal.SIGALRM,worker.Handler.read_timeout)
raw=sys.stdin.buffer.read()
validator=worker.Validator()
validate=validator.validate_questionnaire if sys.argv[1]=='questionnaire' else validator.validate
try:
    assert validate(raw)[0]==200
    first=validator.engine.process.pid
    os.kill(first,signal.SIGSTOP)
    worker.TIMEOUT=1
    status,result=validate(raw)
    assert status==503 and (result.get('status')=='unavailable' if sys.argv[1]=='questionnaire' else result['code']=='validator_unavailable' and not result['valid'])
    assert validator.engine.process is None
    worker.TIMEOUT=120
    assert validate(raw)[0]==200
    second=validator.engine.process.pid
    assert second!=first
    validator.engine.process.kill()
    validator.engine.process.wait(timeout=5)
    assert not validator.engine.ready
    assert validate(raw)[0]==200
    assert validator.engine.process.pid!=second
    print(json.dumps({'timeoutFailedClosed':True,'laterRequestRecovered':True,'deadEngineReplaced':True}),flush=True)
finally:
    validator.close()
'''


def run(command, **kwargs):
    return subprocess.run(command, check=True, timeout=180, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--fixture", required=True, type=Path, help="Synthetic, fully valid exchange event or Questionnaire")
    parser.add_argument("--questionnaire", action="store_true", help="Check the Questionnaire routes instead of exchange admission")
    parser.add_argument("--response", type=Path, help="Synthetic QuestionnaireResponse that answers the Questionnaire fixture")
    parser.add_argument("--expected-identity", required=True)
    args = parser.parse_args()
    purpose = "questionnaire" if args.questionnaire else "event"
    raw = args.fixture.read_bytes()
    if not 0 < len(raw) <= 16 * 1024 * 1024:
        raise ValueError("Fixture size outside worker contract")
    name = "trove-validator-smoke-" + uuid.uuid4().hex[:12]
    resources = ["--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                 "--pids-limit", "128", "--memory", "4g", "--cpus", "2",
                 "--tmpfs", "/tmp:size=2g,mode=1777,noexec,nosuid,nodev",
                 "--ulimit", "fsize=268435456:268435456"]
    network_created = False
    owned_containers = []
    try:
        cli_name = name + "-cli"
        owned_containers.append(cli_name)
        command = ["docker", "run", "--rm", "-i", "--name", cli_name, "--network", "none", *resources,
                   args.image, "--stdin"]
        if args.questionnaire:
            command.append("--questionnaire")
        for payload, expected_exit in ((raw, 0), (b'{"x":1,"x":2}', 1)):
            result = subprocess.run(command, input=payload, capture_output=True, timeout=180, check=False)
            if result.returncode != expected_exit:
                raise RuntimeError("CLI validation did not meet expected outcome: " + result.stdout.decode()[:2048])
            value = json.loads(result.stdout)
            assert value["sha256"] == hashlib.sha256(payload).hexdigest()
            assert value["validatorIdentity"] == args.expected_identity
            if args.questionnaire:
                assert value["status"] == ("valid" if expected_exit == 0 else "invalid")
                assert value["purpose"] == "questionnaire"
            else:
                assert value["valid"] == (expected_exit == 0)
                assert "purpose" not in value
            print(json.dumps({"cliExit": result.returncode, "sha256": value["sha256"]}), flush=True)
        recovery_name = name + "-recovery"
        owned_containers.append(recovery_name)
        run(["docker", "run", "--rm", "-i", "--name", recovery_name, "--network", "none", *resources,
             "--entrypoint", "python3", args.image, "-c", RECOVERY_CLIENT, purpose], input=raw)
        run(["docker", "network", "create", "--internal", name], stdout=subprocess.DEVNULL)
        network_created = True
        worker_name = name + "-worker"
        owned_containers.append(worker_name)
        run(["docker", "run", "--detach", "--name", worker_name, "--network", name, *resources,
             args.image], stdout=subprocess.DEVNULL)
        client_name = name + "-client"
        owned_containers.append(client_name)
        # No host port is exposed. The only client is another isolated container on this internal network.
        run(["docker", "run", "--rm", "-i", "--name", client_name, "--network", name,
             "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
             "--memory", "128m", "--cpus", "1", "--pids-limit", "32",
             "--entrypoint", "python3", args.image, "-c", HTTP_CLIENT, worker_name, args.expected_identity, purpose,
             *([args.response.read_bytes().hex()] if args.response else [])], input=raw)
        print("Offline CLI and private HTTP valid/invalid checks passed.", flush=True)
    finally:
        for container in reversed(owned_containers):
            present = subprocess.run(["docker", "container", "inspect", container], capture_output=True, check=False, timeout=10)
            if present.returncode == 0:
                run(["docker", "container", "rm", "--force", container], stdout=subprocess.DEVNULL)
        if network_created:
            run(["docker", "network", "rm", name], stdout=subprocess.DEVNULL)
        print("Owned validation containers and network cleaned up.", flush=True)


if __name__ == "__main__":
    main()
