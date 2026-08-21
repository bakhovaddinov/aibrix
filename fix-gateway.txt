Here are the direct answers to your questions before we touch anything:

1. **Pod Restart:** Yes. When you apply the updated `StormService` YAML, the cluster will recreate the pod. Because it now has the injection annotation, the Kubernetes Mutating Webhook will intercept the creation and inject the AI Runtime. Your pod will boot with **2/2 containers ready** (your Ascend engine + the AIBrix sidecar) instead of 1/1.
2. **GPU Profiles:** No, you do not have to recreate them. The profiles you generated with `gpu_benchmark.py` live independently inside your Redis cluster. When the new sidecar comes online, the AIBrix control plane will automatically pull those existing profiles from Redis to calculate the `slo-least-load` math.
3. **Band-Aid Cleanup:** Yes, we must clean up our tracks. We aggressively forced custom `HTTPRoute` and `ReferenceGrant` bypasses to try and outsmart the Envoy Gateway. Now that we are building the pod the way Envoy expects, those manual overrides will conflict and break the native routing.

Here is the exact battle plan to get you running on NPUs with full SLO routing.

### Phase 1: Burn the Band-Aids

First, wipe out the manual gateway overrides we created so the AIBrix control plane can manage the routes dynamically.

```bash
kubectl delete httproute qwen257-router -n aibrix-system
kubectl delete httproute qwen257-strict-router -n aibrix-system --ignore-not-found=true
kubectl delete referencegrant aibrix-route-access -n default

```

### Phase 2: Deploy the Correct Architecture

We need to update your `StormService` YAML with the crucial sidecar annotation.

Update your YAML file to look exactly like this (notice the new `sidecar-injection` annotation):

```yaml
apiVersion: orchestration.aibrix.ai/v1alpha1
kind: StormService
metadata:
  name: qwen257
  namespace: default
spec:
  replicas: 1
  updateStrategy:
    type: InPlaceUpdate
  stateful: true
  selector:
    matchLabels:
      app: qwen257
  template:
    metadata:
      labels:
        app: qwen257
        component: vllm-inference
    spec:
      roles:
        - name: prefill
          replicas: 1
          podGroupSize: 1
          stateful: true
          template:
            metadata:
              labels:
                app.kubernetes.io/name: qwen257
                model.aibrix.ai/name: qwen257
                model.aibrix.ai/port: "8008"
                model.aibrix.ai/engine: vllm
              annotations:
                model.aibrix.ai/sidecar-injection: "true"
                model.aibrix.ai/config: |
                  {
                    "lockedRoutingStrategy": "slo-least-load"
                  }	
            spec:
              schedulerName: default-scheduler
              containers:
                - name: prefill
                  image: quay.io/ascend/vllm-ascend:v0.11.0rc1
                  command: ["/bin/bash","-c"]
                  args:
                    - |
                      vllm serve Qwen/Qwen2.5-7B-Instruct \
                      --host 0.0.0.0 \
                      --port 8008 \
                      --tensor-parallel-size 2 \
                      --served-model-name qwen257 \
                      --trust-remote-code \
                      --max-model-len 32768
                  resources:
                    limits:
                      huawei.com/Ascend910: "2"
                    requests:
                      huawei.com/Ascend910: "2"
                  volumeMounts:
                    - name: ascend-drivers
                      mountPath: /usr/local/Ascend/driver
                    - name: localtime
                      mountPath: /etc/localtime
                    - name: data
                      mountPath: /data
                    - name: home
                      mountPath: /home
                    - name: reset-config
                      mountPath: /user/restore/reset/config
                    - name: ranktable
                      mountPath: /user/mindx-dl/ranktable
                    - name: dshm
                      mountPath: /dev/shm
              volumes:
                - name: home
                  hostPath:
                    path: /home
                - name: data
                  hostPath:
                    path: /data
                - name: ascend-drivers
                  hostPath:
                    path: /usr/local/Ascend/driver
                - name: localtime
                  hostPath:
                    path: /etc/localtime
                - name: reset-config
                  hostPath:
                    path: /user/restore/reset/default.reset-config-qwen257
                - name: ranktable
                  hostPath:
                    path: /user/mindx-dl/ranktable/default.qwen257
                - name: dshm
                  emptyDir:
                    medium: Memory

```

Apply the updated YAML:

```bash
kubectl apply -f <your-yaml-file>.yaml

```

### Phase 3: Verify the Sidecar

Wait a minute for the Ascend drivers to mount and the model to load, then check the pods. You are looking for `2/2` under the `READY` column.

```bash
kubectl get pods -l app.kubernetes.io/name=qwen257 -n default

```

### Phase 4: Fire the Request

Once both containers are running, test the gateway via the main Envoy port (8000). The Envoy gateway will natively read your `slo-least-load` annotation, evaluate your Redis profiles, and route the traffic to the sidecar on port 50052, which will instantly proxy it to your NPU on 8008.

```bash
curl -X POST http://localhost:8000/v1/chat/completions \
-H "Content-Type: application/json" \
-d '{"model": "qwen257", "messages": [{"role": "user", "content": "How do you feel about sidecars?"}]}'

```
