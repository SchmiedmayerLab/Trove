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
route='/validate/questionnaire' if purpose=='questionnaire' else '/validate'
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
def check(payload,status,code=None):
    connection=http.client.HTTPConnection(host,8080,timeout=130)
    connection.request('POST',route,body=payload,headers={'Content-Type':'application/fhir+json'})
    response=connection.getresponse(); data=response.read(2049); connection.close()
    assert response.status==status,(response.status,data)
    assert len(data)<=2048
    value=json.loads(data)
    assert value['sha256']==hashlib.sha256(payload).hexdigest()
    assert value['validatorIdentity']==expected
    assert value['valid']==(status==200)
    assert value.get('code')==code
    assert value.get('purpose')==('questionnaire' if purpose=='questionnaire' else None)
    print(json.dumps({'httpStatus':status,'code':code,'sha256':value['sha256']}),flush=True)
check(raw,200)
check(b'{"x":1,"x":2}',422,'invalid_json')
resource=json.loads(raw)
if purpose=='questionnaire':
    del resource['status']
else:
    observation=next(entry['resource'] for entry in resource['entry'] if entry['resource']['resourceType']=='Observation')
    del observation['status']
check(json.dumps(resource,separators=(',',':')).encode(),422,'invalid_fhir')
check(raw,200)
for path in ('/loadIG','/stop','/validateResource','/validate?profile=untrusted'):
    connection=http.client.HTTPConnection(host,8080,timeout=10)
    connection.request('POST',path,body=raw,headers={'Content-Type':'application/fhir+json'})
    response=connection.getresponse(); data=response.read(2049); connection.close()
    assert response.status==400,(path,response.status)
    assert json.loads(data)=={'code':'invalid_request'}
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
    assert status==503 and result['code']=='validator_unavailable' and not result['valid']
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
    parser.add_argument("--questionnaire", action="store_true", help="Check the Questionnaire route instead of exchange admission")
    parser.add_argument("--expected-identity", required=True)
    args = parser.parse_args()
    purpose = "questionnaire" if args.questionnaire else "event"
    raw = args.fixture.read_bytes()
    if not 0 < len(raw) <= 4 * 1024 * 1024:
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
            assert value["valid"] == (expected_exit == 0)
            assert value.get("purpose") == ("questionnaire" if args.questionnaire else None)
            print(json.dumps({"cliExit": result.returncode, **value}), flush=True)
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
             "--entrypoint", "python3", args.image, "-c", HTTP_CLIENT, worker_name, args.expected_identity, purpose], input=raw)
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
