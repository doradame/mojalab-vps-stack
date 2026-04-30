{{- if .Report -}}
{{- with .Report -}}
{{- if ( or .Updated .Failed ) -}}
*Watchtower digest on {{ .Hostname }}*
{{- range .Updated }}
• {{ .ImageName }}: {{ .CurrentImageID.ShortID }} → {{ .LatestImageID.ShortID }}
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
