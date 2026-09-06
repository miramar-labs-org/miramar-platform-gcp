package main

import (
	"encoding/json"
	"testing"
)

func ptr[T any](v T) *T { return &v }

func TestBuildPatch(t *testing.T) {
	tests := []struct {
		name string
		pod  string
		want []jsonPatchOp
	}{
		{
			name: "kfp step pod after nsight injection: both containers privileged + hardened",
			pod: `{"spec":{"containers":[
				{"name":"main","securityContext":{"privileged":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}},
				{"name":"wait","securityContext":{"privileged":true,"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":65532,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}
			]}}`,
			want: []jsonPatchOp{
				{Op: "remove", Path: "/spec/containers/0/securityContext/allowPrivilegeEscalation"},
				{Op: "remove", Path: "/spec/containers/0/securityContext/capabilities"},
				{Op: "replace", Path: "/spec/containers/0/securityContext/seccompProfile", Value: map[string]string{"type": "Unconfined"}},
				{Op: "remove", Path: "/spec/containers/1/securityContext/allowPrivilegeEscalation"},
				{Op: "remove", Path: "/spec/containers/1/securityContext/capabilities"},
				{Op: "replace", Path: "/spec/containers/1/securityContext/seccompProfile", Value: map[string]string{"type": "Unconfined"}},
			},
		},
		{
			name: "idempotent: privileged container already reconciled",
			pod:  `{"spec":{"containers":[{"name":"main","securityContext":{"privileged":true,"seccompProfile":{"type":"Unconfined"}}}]}}`,
			want: nil,
		},
		{
			name: "non-privileged container is left untouched",
			pod:  `{"spec":{"containers":[{"name":"main","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}`,
			want: nil,
		},
		{
			name: "privileged container with explicit capability adds keeps them, drops only the drop list",
			pod:  `{"spec":{"containers":[{"name":"main","securityContext":{"privileged":true,"capabilities":{"add":["SYS_ADMIN"],"drop":["ALL"]}}}]}}`,
			want: []jsonPatchOp{
				{Op: "remove", Path: "/spec/containers/0/securityContext/capabilities/drop"},
			},
		},
		{
			name: "init and ephemeral containers are covered",
			pod: `{"spec":{
				"containers":[{"name":"main","securityContext":{"privileged":true,"allowPrivilegeEscalation":false}}],
				"initContainers":[{"name":"setup","securityContext":{"privileged":true,"allowPrivilegeEscalation":false}}],
				"ephemeralContainers":[{"name":"debug","securityContext":{"privileged":true,"allowPrivilegeEscalation":false}}]
			}}`,
			want: []jsonPatchOp{
				{Op: "remove", Path: "/spec/containers/0/securityContext/allowPrivilegeEscalation"},
				{Op: "remove", Path: "/spec/initContainers/0/securityContext/allowPrivilegeEscalation"},
				{Op: "remove", Path: "/spec/ephemeralContainers/0/securityContext/allowPrivilegeEscalation"},
			},
		},
		{
			name: "pod with no securityContext at all",
			pod:  `{"spec":{"containers":[{"name":"main"}]}}`,
			want: nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var pod podView
			if err := json.Unmarshal([]byte(tc.pod), &pod); err != nil {
				t.Fatalf("unmarshal pod: %v", err)
			}
			got := buildPatch(pod)
			gotJSON, _ := json.Marshal(got)
			wantJSON, _ := json.Marshal(tc.want)
			if string(gotJSON) != string(wantJSON) {
				t.Errorf("buildPatch mismatch\n got: %s\nwant: %s", gotJSON, wantJSON)
			}
		})
	}
}

func TestBuildPatchDoublePassIsNoop(t *testing.T) {
	// Simulate: pass 1 produces a patch; applying it (conceptually) yields a pod
	// with privileged:true and no APE / no all-drop caps / Unconfined seccomp.
	// buildPatch on that state must be empty.
	reconciled := `{"spec":{"containers":[{"name":"main","securityContext":{"privileged":true,"seccompProfile":{"type":"Unconfined"}}}]}}`
	var pod podView
	if err := json.Unmarshal([]byte(reconciled), &pod); err != nil {
		t.Fatal(err)
	}
	if ops := buildPatch(pod); len(ops) != 0 {
		t.Errorf("expected no-op on reconciled pod, got %v", ops)
	}
}
