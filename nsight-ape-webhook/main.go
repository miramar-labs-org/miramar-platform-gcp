// nsight-ape-webhook is a tiny mutating admission webhook that reconciles the
// NVIDIA Nsight Operator's process-hook injection with Kubeflow Pipelines' (and
// any PSS-hardened) step pods.
//
// The Nsight injector adds `securityContext.privileged: true` to every container
// of a pod labelled `nvidia-nsight-profile=enabled` (privileged is required for
// GB10 hardware GPU trace — ~7 kernel records without it, ~47 with). KFP bakes
// `allowPrivilegeEscalation: false` + `capabilities.drop: [ALL]` +
// `seccompProfile: RuntimeDefault` into its step containers at compile time, and
// those cannot be overridden through the KFP SDK. The Kubernetes apiserver then
// rejects the pod: "cannot set 'allowPrivilegeEscalation' to false and
// 'privileged' to true".
//
// This webhook runs with reinvocationPolicy: IfNeeded, so it is re-invoked after
// the Nsight injector mutates the pod. For every container whose
// securityContext.privileged == true it:
//   - removes securityContext.allowPrivilegeEscalation   (resolves the apiserver conflict)
//   - removes an all-drop securityContext.capabilities    (privileged + drop ALL is contradictory)
//   - rewrites seccompProfile RuntimeDefault -> Unconfined (so perf_event_open is not filtered)
//
// It only ever touches containers the Nsight injector already marked privileged,
// on pods carrying the profiling label. It fails open (failurePolicy: Ignore).
//
// The binary self-signs its serving certificate on startup and patches its own
// MutatingWebhookConfiguration's caBundle — the same bootstrap pattern the Nsight
// injector uses. No cert-manager dependency.
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"time"
)

const (
	svcName = "nsight-ape-webhook"
	mwcName = "nsight-ape-webhook"
	addr    = ":8443"
)

func namespace() string {
	if b, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace"); err == nil {
		if s := string(bytes.TrimSpace(b)); s != "" {
			return s
		}
	}
	return "nsight-operator"
}

// genCert returns a self-signed cert usable both as the serving certificate and
// as its own CA bundle (IsCA + serverAuth, SANs for the in-cluster Service).
func genCert(ns string) (tls.Certificate, []byte, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	dns := []string{
		svcName,
		svcName + "." + ns,
		svcName + "." + ns + ".svc",
		svcName + "." + ns + ".svc.cluster.local",
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: svcName + "." + ns + ".svc"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              dns,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	return tlsCert, certPEM, err
}

// patchCABundle writes caPEM into mutatingwebhookconfigurations/<mwcName>
// webhooks[0].clientConfig.caBundle using the pod's service-account token.
func patchCABundle(caPEM []byte) error {
	host := os.Getenv("KUBERNETES_SERVICE_HOST")
	port := os.Getenv("KUBERNETES_SERVICE_PORT")
	if host == "" || port == "" {
		return fmt.Errorf("not running in-cluster (KUBERNETES_SERVICE_HOST unset)")
	}
	token, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	if err != nil {
		return err
	}
	caCert, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
	if err != nil {
		return err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caCert) {
		return fmt.Errorf("could not parse in-cluster CA")
	}
	client := &http.Client{
		Timeout:   15 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}},
	}
	url := fmt.Sprintf("https://%s:%s/apis/admissionregistration.k8s.io/v1/mutatingwebhookconfigurations/%s", host, port, mwcName)
	patch := fmt.Sprintf(`[{"op":"replace","path":"/webhooks/0/clientConfig/caBundle","value":%q}]`,
		base64.StdEncoding.EncodeToString(caPEM))
	req, err := http.NewRequest(http.MethodPatch, url, bytes.NewBufferString(patch))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+string(bytes.TrimSpace(token)))
	req.Header.Set("Content-Type", "application/json-patch+json")
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		rb, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("%s: %s", resp.Status, string(rb))
	}
	return nil
}

type admissionReview struct {
	APIVersion string             `json:"apiVersion"`
	Kind       string             `json:"kind"`
	Request    *admissionRequest  `json:"request,omitempty"`
	Response   *admissionResponse `json:"response,omitempty"`
}

type admissionRequest struct {
	UID    string          `json:"uid"`
	Object json.RawMessage `json:"object"`
}

type admissionResponse struct {
	UID       string `json:"uid"`
	Allowed   bool   `json:"allowed"`
	Patch     []byte `json:"patch,omitempty"` // encoding/json base64-encodes []byte — exactly what the API expects
	PatchType string `json:"patchType,omitempty"`
}

type podView struct {
	Spec struct {
		Containers          []containerView `json:"containers"`
		InitContainers      []containerView `json:"initContainers"`
		EphemeralContainers []containerView `json:"ephemeralContainers"`
	} `json:"spec"`
}

type containerView struct {
	SecurityContext *struct {
		Privileged               *bool `json:"privileged"`
		AllowPrivilegeEscalation *bool `json:"allowPrivilegeEscalation"`
		Capabilities             *struct {
			Add  []string `json:"add"`
			Drop []string `json:"drop"`
		} `json:"capabilities"`
		SeccompProfile *struct {
			Type string `json:"type"`
		} `json:"seccompProfile"`
	} `json:"securityContext"`
}

type jsonPatchOp struct {
	Op    string `json:"op"`
	Path  string `json:"path"`
	Value any    `json:"value,omitempty"`
}

// buildPatch computes the idempotent JSON-Patch for a pod. Empty result means the
// pod is already consistent (or has no privileged containers) — nothing to do.
func buildPatch(pod podView) []jsonPatchOp {
	var ops []jsonPatchOp
	visit := func(list string, i int, c containerView) {
		sc := c.SecurityContext
		if sc == nil || sc.Privileged == nil || !*sc.Privileged {
			return
		}
		base := fmt.Sprintf("/spec/%s/%d/securityContext", list, i)
		if sc.AllowPrivilegeEscalation != nil {
			ops = append(ops, jsonPatchOp{Op: "remove", Path: base + "/allowPrivilegeEscalation"})
		}
		if sc.Capabilities != nil {
			switch {
			case len(sc.Capabilities.Add) == 0:
				ops = append(ops, jsonPatchOp{Op: "remove", Path: base + "/capabilities"})
			case len(sc.Capabilities.Drop) > 0:
				ops = append(ops, jsonPatchOp{Op: "remove", Path: base + "/capabilities/drop"})
			}
		}
		if sc.SeccompProfile != nil && sc.SeccompProfile.Type == "RuntimeDefault" {
			ops = append(ops, jsonPatchOp{Op: "replace", Path: base + "/seccompProfile", Value: map[string]string{"type": "Unconfined"}})
		}
	}
	for i, c := range pod.Spec.Containers {
		visit("containers", i, c)
	}
	for i, c := range pod.Spec.InitContainers {
		visit("initContainers", i, c)
	}
	for i, c := range pod.Spec.EphemeralContainers {
		visit("ephemeralContainers", i, c)
	}
	return ops
}

func handleMutate(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 3<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	var ar admissionReview
	if err := json.Unmarshal(body, &ar); err != nil || ar.Request == nil {
		http.Error(w, "bad AdmissionReview", http.StatusBadRequest)
		return
	}

	resp := &admissionResponse{UID: ar.Request.UID, Allowed: true}
	var pod podView
	if err := json.Unmarshal(ar.Request.Object, &pod); err != nil {
		log.Printf("uid=%s: cannot parse pod, allowing unchanged: %v", ar.Request.UID, err)
	} else if ops := buildPatch(pod); len(ops) > 0 {
		if pb, err := json.Marshal(ops); err == nil {
			resp.Patch = pb
			resp.PatchType = "JSONPatch"
			log.Printf("uid=%s: applied %d patch op(s)", ar.Request.UID, len(ops))
		}
	}

	out := admissionReview{APIVersion: "admission.k8s.io/v1", Kind: "AdmissionReview", Response: resp}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(out); err != nil {
		log.Printf("uid=%s: encode response: %v", ar.Request.UID, err)
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	ns := namespace()

	cert, caPEM, err := genCert(ns)
	if err != nil {
		log.Fatalf("generate serving certificate: %v", err)
	}

	var patchErr error
	for attempt := 1; attempt <= 12; attempt++ {
		if patchErr = patchCABundle(caPEM); patchErr == nil {
			log.Printf("patched caBundle on mutatingwebhookconfiguration/%s", mwcName)
			break
		}
		log.Printf("caBundle patch attempt %d/12 failed: %v", attempt, patchErr)
		time.Sleep(5 * time.Second)
	}
	if patchErr != nil {
		log.Fatalf("could not patch caBundle after retries: %v", patchErr)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", handleMutate)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("nsight-ape-webhook listening on %s (namespace=%s)", addr, ns)
	log.Fatal(srv.ListenAndServeTLS("", ""))
}
