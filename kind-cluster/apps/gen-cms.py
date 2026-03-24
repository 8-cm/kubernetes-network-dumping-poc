#!/usr/bin/env python3
"""Generate ConfigMap YAML files for hello-nginx and traffic-monitor pods."""

NAMESPACES = [
    ("team-alpha", "#38bdf8", "linear-gradient(135deg,#1e3a5f,#1e293b)", "#334155"),
    ("team-beta",  "#34d399", "linear-gradient(135deg,#064e3b,#022c22)", "#065f46"),
    ("team-gamma", "#fbbf24", "linear-gradient(135deg,#78350f,#1c1208)", "#92400e"),
]


def indent(text, n=4):
    prefix = " " * n
    lines = text.splitlines()
    # Strip trailing empty lines
    while lines and not lines[-1].strip():
        lines.pop()
    result = []
    for line in lines:
        if line.strip():
            result.append(prefix + line)
        else:
            result.append("")
    return "\n".join(result)


HELLO_CONF = r"""log_format req '$time_local | $remote_addr:$remote_port | "$request" | $status | $http_user_agent';

server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    access_log /dev/stdout req;
    access_log /data/in.log req;

    location / {
        try_files $uri $uri/ =404;
    }

    location /logs/in {
        access_log off;
        alias /data/in.log;
        default_type "text/plain; charset=utf-8";
        add_header Cache-Control "no-store";
    }

    location /logs/out {
        access_log off;
        alias /data/out.log;
        default_type "text/plain; charset=utf-8";
        add_header Cache-Control "no-store";
    }
}
"""

TRAFFIC_CONF = r"""server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location /logs/in {
        access_log off;
        alias /data/in.log;
        default_type "text/plain; charset=utf-8";
        add_header Cache-Control "no-store";
    }

    location /logs/out {
        access_log off;
        alias /data/out.log;
        default_type "text/plain; charset=utf-8";
        add_header Cache-Control "no-store";
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
"""

HTML_TMPL = r"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>${NAMESPACE}</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{background:__BG__;font-family:'JetBrains Mono',monospace,ui-monospace;font-size:.8rem;color:#cbd5e1;min-height:100vh}
    .hero{border-bottom:1px solid __BORDER__;padding:.6rem 1rem .5rem;display:flex;align-items:center;justify-content:space-between;background:rgba(0,0,0,.25)}
    h1{font-size:1rem;font-weight:700;color:__ACCENT__;letter-spacing:.05em}
    .badge{display:inline-block;padding:.1rem .45rem;border-radius:.25rem;font-size:.65rem;margin-left:.3rem;border:1px solid __BORDER__}
    .b-ns{color:__ACCENT__;border-color:__ACCENT__}
    .b-pod{color:#94a3b8}
    .b-node{color:#64748b}
    .cols{display:flex;gap:.5rem;padding:.5rem;flex-wrap:wrap}
    .col{flex:1;min-width:320px;display:flex;flex-direction:column}
    .full{padding:.5rem;display:flex;flex-direction:column}
    .pt{font-size:.7rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;padding:.25rem .4rem;background:rgba(0,0,0,.3);border:1px solid __BORDER__;border-bottom:none;border-radius:.25rem .25rem 0 0;color:__ACCENT__;display:flex;align-items:center;gap:.4rem}
    .box{height:280px;overflow-y:auto;background:rgba(0,0,0,.45);border:1px solid __BORDER__;border-radius:0 0 .25rem .25rem;padding:.3rem .4rem;font-size:.72rem;line-height:1.5}
    .bw{height:220px;overflow-y:auto;background:rgba(0,0,0,.45);border:1px solid __BORDER__;border-radius:0 0 .25rem .25rem;padding:.3rem .4rem;font-size:.72rem;line-height:1.5}
    .e{display:block;padding:.15rem 0;border-bottom:1px solid #0f172a;white-space:pre;color:#94a3b8}
    .ts{color:#475569}
    .c-in{color:#34d399}
    .c-out{color:#fb923c}
    .t-i{color:#60a5fa}
    .t-c{color:#a78bfa}
    .t-e{color:#f97316}
    .ip{color:__ACCENT__}
    .rq{color:#f59e0b}
    .s2{color:#22c55e}
    .s4{color:#ef4444}
    .s5{color:#dc2626}
    .st{color:#f59e0b}
    .sr{color:#f87171}
    .dim{color:#334155;font-style:italic}
    .ft{font-size:.65rem;color:#334155;margin-top:.3rem;text-align:right}
    .dot{width:7px;height:7px;border-radius:50%;display:inline-block;animation:blink 2s infinite}
    .di{background:#34d399}
    .do{background:#fb923c}
    .dm{background:__ACCENT__}
    @keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}
  </style>
</head>
<body>
  <div class="hero">
    <h1>${NAMESPACE}</h1>
    <div>
      <span class="badge b-ns">ns:&nbsp;${NAMESPACE}</span>
      <span class="badge b-pod">pod:&nbsp;${POD_NAME}</span>
      <span class="badge b-node">node:&nbsp;${NODE_NAME}</span>
    </div>
  </div>
  <div class="cols">
    <div class="col">
      <div class="pt"><span class="dot di"></span>&#8592;&nbsp;Incoming</div>
      <div class="box" id="bi"><span class="dim">Waiting&#8230;</span></div>
      <div class="ft" id="ti">&#8211;</div>
    </div>
    <div class="col">
      <div class="pt"><span class="dot do"></span>&#8594;&nbsp;Outgoing</div>
      <div class="box" id="bo"><span class="dim">Waiting&#8230;</span></div>
      <div class="ft" id="to_">&#8211;</div>
    </div>
  </div>
  <div class="full">
    <div class="pt"><span class="dot dm"></span>&#8644;&nbsp;Combined</div>
    <div class="bw" id="bc"><span class="dim">Waiting&#8230;</span></div>
    <div class="ft" id="tc">&#8211;</div>
  </div>
  <script>
    var bi=document.getElementById('bi'),bo=document.getElementById('bo'),bc=document.getElementById('bc');
    var ti=document.getElementById('ti'),to_=document.getElementById('to_'),tc=document.getElementById('tc');
    var inL=[],outL=[];
    function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
    function tsOf(l){return l[0]==='['?l.slice(1,9):l.slice(12,20);}
    function ciC(l){
      var p=l.split(' | ');
      if(p.length<4)return esc(l);
      var sc=p[3].trim(),cl=sc[0]==='2'?'s2':sc[0]==='4'?'s4':sc[0]==='5'?'s5':'';
      return '<span class="ts">'+esc(l.slice(12,20))+'</span> '
        +'<span class="ip">'+esc(p[1].trim().padEnd(22))+'</span> '
        +'<span class="rq">'+esc(p[2].trim().slice(0,38))+'</span> '
        +'<span class="'+cl+'">'+esc(sc)+'</span>';
    }
    function coC(l){
      if(l.length<12)return esc(l);
      var t=l.slice(1,9),rest=l.slice(11),a=rest.indexOf(' \u2192 ');
      if(a<0)return esc(l);
      var tp=rest.slice(0,a).trim(),af=rest.slice(a+3),ci2=af.lastIndexOf(': ');
      if(ci2<0)return esc(l);
      var tgt=af.slice(0,ci2),cd=af.slice(ci2+2).trim();
      var tc2=tp==='internal'?'t-i':tp==='cross'?'t-c':'t-e';
      var cc=cd[0]==='2'?'s2':cd[0]==='4'?'s4':cd[0]==='5'?'s5':cd==='timeout'?'st':cd==='refused'?'sr':'';
      return '<span class="ts">['+esc(t)+']</span> '
        +'<span class="'+tc2+'">'+esc(tp.padEnd(8))+'</span>'
        +'<span class="ts"> \u2192 </span>'
        +'<span class="ip">'+esc(tgt.padEnd(50))+'</span>'
        +'<span class="'+cc+'">'+esc(cd)+'</span>';
    }
    function ri(l){return'<span class="e">'+ciC(l)+'</span>';}
    function ro(l){return'<span class="e">'+coC(l)+'</span>';}
    function uc(){
      var merged=inL.map(function(l){return{l:l,d:'in'};}).concat(outL.map(function(l){return{l:l,d:'out'};}));
      merged.sort(function(a,b){return tsOf(a.l)<tsOf(b.l)?-1:tsOf(a.l)>tsOf(b.l)?1:0;});
      var last=merged.slice(-30);
      bc.innerHTML=last.map(function(x){
        var arrow=x.d==='in'?'<span class="c-in">\u2190</span>':'<span class="c-out">\u2192</span>';
        var content=x.d==='in'?ciC(x.l):coC(x.l);
        return '<span class="e">'+arrow+' '+content+'</span>';
      }).join('')||'<span class="dim">Waiting\u2026</span>';
      bc.scrollTop=bc.scrollHeight;
      tc.textContent='updated '+new Date().toLocaleTimeString();
    }
    function fi(){
      fetch('logs/in').then(function(r){return r.text();}).then(function(t){
        var lines=t.split('\n').filter(function(l){return l.trim();});
        inL=lines.slice(-100);
        bi.innerHTML=inL.map(ri).join('')||'<span class="dim">Waiting\u2026</span>';
        bi.scrollTop=bi.scrollHeight;
        ti.textContent='updated '+new Date().toLocaleTimeString();
        uc();
      }).catch(function(){});
    }
    function fo(){
      fetch('logs/out').then(function(r){return r.text();}).then(function(t){
        var lines=t.split('\n').filter(function(l){return l.trim();});
        outL=lines.slice(-100);
        bo.innerHTML=outL.map(ro).join('')||'<span class="dim">Waiting\u2026</span>';
        bo.scrollTop=bo.scrollHeight;
        to_.textContent='updated '+new Date().toLocaleTimeString();
        uc();
      }).catch(function(){});
    }
    function load(){fi();fo();}
    load();setInterval(load,2000);
  </script>
</body>
</html>
"""


def make_cm(name, namespace, conf, html):
    conf_indented = indent(conf)
    html_indented = indent(html)
    return f"""\
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {name}
  namespace: {namespace}
data:
  default.conf: |
{conf_indented}
  index.html: |
{html_indented}
"""


def main():
    hello_docs = []
    traffic_docs = []

    for ns, accent, bg, border in NAMESPACES:
        html = (HTML_TMPL
                .replace("__ACCENT__", accent)
                .replace("__BG__", bg)
                .replace("__BORDER__", border))

        hello_docs.append(make_cm("hello-nginx", ns, HELLO_CONF, html))
        traffic_docs.append(make_cm("traffic-dashboard", ns, TRAFFIC_CONF, html))

    hello_path = "/Users/jirkatvrdon3/Projects/installfest/kind-cluster/apps/hello-nginx-cm.yaml"
    traffic_path = "/Users/jirkatvrdon3/Projects/installfest/kind-cluster/apps/traffic-dashboard-cm.yaml"

    with open(hello_path, "w") as f:
        f.write("".join(hello_docs))

    with open(traffic_path, "w") as f:
        f.write("".join(traffic_docs))

    print(f"Wrote {hello_path}")
    print(f"Wrote {traffic_path}")


if __name__ == "__main__":
    main()
