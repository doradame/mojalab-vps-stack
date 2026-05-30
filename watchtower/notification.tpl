{{- if .Report -}}
{{- with .Report -}}
{{- if ( or .Updated .Stale .Failed ) -}}
*Watchtower digest on {{ .Hostname }}*
{{- range .Stale }}
🆕 {{ .ImageName }}: update available
{{- end -}}
{{- range .Updated }}
✅ {{ .ImageName }}: {{ .CurrentImageID.ShortID }} → {{ .LatestImageID.ShortID }}
{{- end -}}
{{- range .Failed }}
❌ {{ .ImageName }}: {{ .Error }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{ range . }}{{ .Message }}
{{ end -}}
{{- end -}}
