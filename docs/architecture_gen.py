# -*- coding: utf-8 -*-
"""
Nguồn duy nhất của sơ đồ kiến trúc. Toạ độ đặt tay, sinh ra:
  docs/architecture.drawio  — shape AWS4, mở sửa bằng app.diagrams.net
  docs/architecture.svg     — cùng toạ độ, nhúng icon AWS chính thức

Mọi thành phần lấy từ deploy/terraform/. Chạy:
  pip install diagrams cairosvg
  python docs/architecture_gen.py
"""
import sys, html, base64, pathlib

def E(s): return html.escape(s, quote=True)

W, H = 2140, 1400
INK, MUT = "#232F3E", "#5A6B7B"
NET, STO, CMP, DB, INT, SEC, MGT, MIG = ("#8C4FFF", "#7AA116", "#ED7100", "#C925D1",
                                         "#E7157B", "#DD344C", "#E7157B", "#01A88D")

# ---- container: id, nhãn, x, y, w, h, loại, grIcon, màu
BOXES = [
 ("onprem","On-premise  ·  ABC Manufacturing  —  ngắt sau cutover", 40, 860, 250, 370, "onprem","", MUT),
 ("cloud", "AWS Cloud",                          320, 100, 1760, 1200, "aws","group_aws_cloud",     INK),
 ("region","Region  ap-southeast-1",             500, 150, 1550, 1130, "aws","group_region",        "#147EBA"),
 ("vpc",   "VPC  10.0.0.0/16",                   560, 220, 1420,  840, "aws","group_vpc2",          "#248814"),
 ("az_a",  "Availability Zone  ap-southeast-1a", 600, 300,  640,  740, "az","",                     "#147EBA"),
 ("az_b",  "Availability Zone  ap-southeast-1b",1300, 300,  640,  740, "az","",                     "#147EBA"),
 ("pub_a", "public subnet  10.0.0.0/24  ·  route 0.0.0.0/0 → IGW",   620, 360, 600, 190, "aws","group_public_subnet",  STO),
 ("pub_b", "public subnet  10.0.1.0/24  ·  route 0.0.0.0/0 → IGW",  1320, 360, 600, 190, "aws","group_public_subnet",  STO),
 ("prv_a", "private subnet  10.0.10.0/24  ·  route 0.0.0.0/0 → NAT", 620, 580, 600, 180, "aws","group_private_subnet","#00A4A6"),
 ("prv_b", "private subnet  10.0.11.0/24  ·  route 0.0.0.0/0 → NAT",1320, 580, 600, 180, "aws","group_private_subnet","#00A4A6"),
 ("dat_a", "data subnet  10.0.20.0/24  ·  route table chỉ có local", 620, 800, 600, 220, "aws","group_private_subnet","#DD6B10"),
 ("dat_b", "data subnet  10.0.21.0/24  ·  route table chỉ có local",1320, 800, 600, 220, "aws","group_private_subnet","#DD6B10"),
 ("svc",   "Dịch vụ region  ·  ngoài VPC",       580,1090, 1400,  170, "az","",                     MUT),
]
# ---- dải trải ngang hai AZ: id, nhãn, x, y, w, h, màu, nền
SPANS = [
 ("alb","Application Load Balancer  ·  internet-facing  ·  listener :80  →  target group :8080 HTTP  ·  target-type instance  ·  health check /ready 10s (2/2)  ·  sg-alb-public",
  640, 395, 1260, 56, NET, "#F6F1FF"),
 ("asg","Auto Scaling group  ·  Amazon Linux 2023 arm64 (Graviton)  ·  min 2 / max 6  ·  warm pool Stopped  ·  target tracking ALBRequestCountPerTarget  ·  sg-app",
  640, 615, 1260, 130, CMP, "#FEF3EC"),
 ("prx","RDS Proxy  ·  POSTGRESQL  ·  TLS bắt buộc  ·  sg-rds-proxy", 800, 835, 700, 52, DB, "#FBF0FC"),
]
# ---- icon: id, nhãn(| = xuống dòng), x, y, size, resIcon(drawio), png, nền
ICONS = [
 ("users","Người dùng",                100, 620, 78,"users",           "onprem/client/users.png",            "#FFFFFF"),
 ("ows",  "Web server",                 70, 910, 48,"traditional_server","onprem/network/nginx.png",         "#FFFFFF"),
 ("oas",  "App server",                175, 910, 48,"traditional_server","onprem/compute/server.png",        "#FFFFFF"),
 ("odb",  "PostgreSQL",                 70,1020, 48,"traditional_server","onprem/database/postgresql.png",   "#FFFFFF"),
 ("ofs",  "File server",               175,1020, 48,"traditional_server","generic/storage/storage.png",      "#FFFFFF"),
 ("cf",   "CloudFront|2 origin · OAC", 370, 620, 78,"cloudfront",      "aws/network/cloudfront.png",          NET),
 ("igw",  "Internet Gateway",         1240, 190, 60,"internet_gateway","aws/network/internet-gateway.png",    NET),
 ("nat",  "NAT Gateway|+ Elastic IP",  680, 465, 56,"nat_gateway",     "aws/network/nat-gateway.png",         NET),
 ("ec2a", "EC2 App tier|+ Worker",     860, 640, 56,"ec2",             "aws/compute/ec2.png",                 CMP),
 ("ec2b", "EC2 App tier|+ Worker",    1560, 640, 56,"ec2",             "aws/compute/ec2.png",                 CMP),
 ("mta",  "EFS mount target",          680, 900, 56,"elastic_file_system","aws/storage/elastic-file-system-efs.png", STO),
 ("dsy",  "DataSync|S3 → EFS",         840, 900, 56,"datasync",        "aws/migration/datasync.png",          MIG),
 ("rdsa", "RDS PostgreSQL|primary · sg-rds",1000,900,56,"rds",         "aws/database/rds-instance.png",       DB),
 ("dms",  "DMS|full-load + CDC",      1160, 900, 56,"database_migration_service","aws/migration/database-migration-service.png", MIG),
 ("rdsb", "RDS PostgreSQL|standby",   1380, 900, 56,"rds",             "aws/database/rds-instance.png",       DB),
 ("mtb",  "EFS mount target",         1560, 900, 56,"elastic_file_system","aws/storage/elastic-file-system-efs.png", STO),
 ("s3st", "S3 · staging|file nguồn",   626,1120, 48,"s3",              "aws/storage/simple-storage-service-s3.png", STO),
 ("s3as", "S3 · SPA assets|OAC, versioning",766,1120,48,"s3",          "aws/storage/simple-storage-service-s3.png", STO),
 ("s3ar", "S3 · artifacts|bản build app",906,1120,48,"s3",             "aws/storage/simple-storage-service-s3.png", STO),
 ("s3lg", "S3 · ALB access log",      1046,1120, 48,"s3",              "aws/storage/simple-storage-service-s3.png", STO),
 ("sqs",  "SQS FIFO orders|+ DLQ, redrive",1186,1120,48,"sqs",         "aws/integration/simple-queue-service-sqs.png", INT),
 ("ddb",  "DynamoDB|accept store",    1326,1120, 48,"dynamodb",        "aws/database/dynamodb.png",           DB),
 ("efs",  "EFS file system|2 mount target",1466,1120,48,"elastic_file_system","aws/storage/elastic-file-system-efs.png", STO),
 ("sm",   "Secrets Manager|mật khẩu master",1606,1120,48,"secrets_manager","aws/security/secrets-manager.png",SEC),
 ("ssm",  "SSM Parameter Store|tham số DB",1746,1120,48,"systems_manager_parameter_store","aws/management/systems-manager-parameter-store.png", MGT),
 ("cw",   "CloudWatch + SNS|log · 8 alarm · email",1886,1120,48,"cloudwatch_2","aws/management/cloudwatch.png", MGT),
]
# ---- cạnh: các điểm gãy, nhãn, nét đứt, vị trí nhãn (0..1)
EDGES = [
 ([(178,659),(370,659)],                                        "HTTPS",              0, 0.5),
 ([(409,698),(409,1230),(766,1230),(766,1168)],                 "default → S3 assets · OAC", 0, 0.55),
 ([(409,620),(409,423),(640,423)],                              "/api/*  ·  CachingDisabled", 0, 0.78),
 ([(1270,250),(1270,395)],                                      "ingress",            0, 0.5),
 ([(888,451),(888,640)],                                        "8080",               0, 0.6),
 ([(1588,451),(1588,640)],                                      "8080",               0, 0.6),
 ([(860,660),(708,660),(708,521)],                              "egress",             1, 0.75),
 ([(680,493),(612,493),(612,330),(1270,330),(1270,250)],        "",                   1, 0.5),
 ([(888,696),(888,835)],                                        "4 · commit rồi mới xoá message", 0, 0.55),
 ([(1560,660),(1460,660),(1460,835)],                           "",                   1, 0.5),
 ([(1028,887),(1028,900)],                                      "5432 · TLS",         0, 0.5),
 ([(1408,887),(1408,900)],                                      "",                   1, 0.5),
 ([(1028,1005),(1408,1005)],                                    "đồng bộ Multi-AZ",   1, 0.5),
 ([(860,675),(708,675),(708,900)],                              "NFS 2049 · TLS",     0, 0.66),
 ([(1588,696),(1588,900)],                                      "NFS 2049 · TLS",     0, 0.38),
 ([(1616,668),(1945,668),(1945,1070),(1210,1070),(1210,1120)],  "2 · SendMessage  ·  3 · long poll 20s", 0, 0.62),
 ([(1616,655),(1965,655),(1965,1082),(1350,1082),(1350,1120)],  "1 · PutItem  ·  ConditionExpression",   0, 0.62),
 ([(1500,861),(1955,861),(1955,1094),(1630,1094),(1630,1120)],  "xác thực proxy",     1, 0.60),
 ([(118,1044),(1188,1044),(1188,956)],                          "DMS  ·  full-load + CDC  ·  không mất giao dịch", 0, 0.42),
 ([(1160,928),(1056,928)],                                      "",                   0, 0.5),
 ([(199,1068),(199,1145),(626,1145)],                           "đẩy file lên S3",    1, 0.3),
 ([(650,1120),(650,1062),(868,1062),(868,956)],                 "",                   1, 0.5),
 ([(840,928),(736,928)],                                        "ghi vào EFS",        0, 0.5),
]
NOTE = ("Tầng data chỉ có route local — không gắn IGW, không gắn NAT. Một NAT Gateway duy nhất ở AZ 1a, cả hai private subnet đều đi qua nó.   "
        "API trả 202 Accepted; worker chỉ xoá message khỏi SQS sau khi transaction commit thành công.   "
        "sg-rds còn mở 5432 trực tiếp từ sg-app làm đường dự phòng khi RDS Proxy lỗi.   "
        "Hai EFS mount target thuộc cùng một file system, phân quyền bằng access point theo phòng ban (0770) và một access point dùng chung /public (0775).   "
        "S3 artifacts, S3 ALB access log, SSM Parameter Store và CloudWatch được stack tạo và sử dụng nhưng không vẽ đường nối để sơ đồ đỡ rối.")

# --------------------------------------------------------------- draw.io
AWSG = ("sketch=0;outlineConnect=0;gradientColor=none;html=1;whiteSpace=wrap;fontSize=12;fontStyle=0;"
        "container=1;pointerEvents=0;collapsible=0;recursiveResize=0;shape=mxgraph.aws4.group;"
        "grIcon=mxgraph.aws4.{i};strokeColor={c};fillColor=none;verticalAlign=top;align=left;"
        "spacingLeft=30;fontColor={c};dashed=0;")
AZG = ("rounded=0;html=1;whiteSpace=wrap;fillColor=none;strokeColor={c};dashed=1;dashPattern=8 6;"
       "verticalAlign=top;align=left;spacingLeft=10;spacingTop=2;fontSize=12;fontColor={c};"
       "container=1;pointerEvents=0;collapsible=0;")
SPN = ("rounded=1;arcSize=6;html=1;whiteSpace=wrap;fillColor={f};strokeColor={c};strokeWidth=1.5;"
       "dashed=1;dashPattern=6 4;verticalAlign=top;align=center;spacingTop=4;fontSize=10;fontColor={c};"
       "container=1;pointerEvents=0;collapsible=0;")
ICO = ("sketch=0;outlineConnect=0;fontColor=#232F3E;fillColor={f};strokeColor=#ffffff;dashed=0;"
       "verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=10;fontStyle=0;"
       "aspect=fixed;shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.{i};")
EDG = ("edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;jettySize=auto;orthogonalLoop=1;"
       "strokeColor=#5A6B7B;strokeWidth=1.5;fontSize=10;fontColor=#5A6B7B;"
       "labelBackgroundColor=#FFFFFF;endArrow=block;endFill=1;{d}")

def build_drawio():
    o = ['<mxfile host="app.diagrams.net">', '  <diagram id="arch" name="AWS architecture">',
         f'    <mxGraphModel dx="{W}" dy="{H}" grid="0" gridSize="10" guides="1" page="1" '
         f'pageWidth="{W}" pageHeight="{H}" background="#FFFFFF" math="0" shadow="0">',
         '      <root><mxCell id="0"/><mxCell id="1" parent="0"/>']
    for bid, lb, x, y, w, h, kind, ic, c in BOXES:
        st = AWSG.format(i=ic, c=c) if kind == "aws" else AZG.format(c=c)
        o.append(f'        <mxCell id="{bid}" value="{E(lb)}" style="{st}" vertex="1" parent="1">'
                 f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
    for sid, lb, x, y, w, h, c, f in SPANS:
        o.append(f'        <mxCell id="{sid}" value="{E(lb)}" style="{SPN.format(f=f,c=c)}" vertex="1" parent="1">'
                 f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
    for nid, lb, x, y, s, ic, _png, f in ICONS:
        o.append(f'        <mxCell id="{nid}" value="{E(lb).replace("|","&lt;br&gt;")}" '
                 f'style="{ICO.format(i=ic,f=f)}" vertex="1" parent="1">'
                 f'<mxGeometry x="{x}" y="{y}" width="{s}" height="{s}" as="geometry"/></mxCell>')
    for i, (pts, lb, dash, _t) in enumerate(EDGES):
        mids = "".join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in pts[1:-1])
        o.append(f'        <mxCell id="ed{i}" value="{E(lb)}" style="{EDG.format(d="dashed=1;" if dash else "")}" '
                 f'edge="1" parent="1"><mxGeometry relative="1" as="geometry">'
                 f'<mxPoint x="{pts[0][0]}" y="{pts[0][1]}" as="sourcePoint"/>'
                 f'<mxPoint x="{pts[-1][0]}" y="{pts[-1][1]}" as="targetPoint"/>'
                 + (f'<Array as="points">{mids}</Array>' if mids else '') + '</mxGeometry></mxCell>')
    o.append(f'        <mxCell id="note" value="{E(NOTE)}" style="text;html=1;align=left;verticalAlign=top;'
             f'fontSize=11;fontColor={MUT};whiteSpace=wrap;" vertex="1" parent="1">'
             f'<mxGeometry x="40" y="1315" width="2050" height="90" as="geometry"/></mxCell>')
    o += ['      </root></mxGraphModel>', '  </diagram>', '</mxfile>']
    return "\n".join(o)

# ------------------------------------------------------------------- SVG
def build_svg(icon_root):
    def uri(rel):
        return "data:image/png;base64," + base64.b64encode((pathlib.Path(icon_root)/rel).read_bytes()).decode()

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
         f'viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
         f'font-family="Helvetica Neue, Helvetica, Arial, sans-serif">',
         f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>',
         f'<defs><marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
         f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{MUT}"/></marker></defs>']
    for bid, lb, x, y, w, h, kind, ic, c in BOXES:
        dash = ' stroke-dasharray="8 6"' if kind in ("az", "onprem") else ''
        o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="none" stroke="{c}" '
                 f'stroke-width="1.8"{dash}/>')
        o.append(f'<text x="{x+12}" y="{y+20}" font-size="12.5" font-weight="600" fill="{c}">{E(lb)}</text>')
    for sid, lb, x, y, w, h, c, f in SPANS:
        o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{f}" stroke="{c}" '
                 f'stroke-width="1.5" stroke-dasharray="6 4"/>')
        o.append(f'<text x="{x+w/2:.0f}" y="{y+17}" font-size="10.5" font-weight="600" fill="{c}" '
                 f'text-anchor="middle">{E(lb)}</text>')
    for pts, lb, dash, tf in EDGES:
        d = " ".join(("M" if i == 0 else "L") + f"{px},{py}" for i, (px, py) in enumerate(pts))
        da = ' stroke-dasharray="6 4"' if dash else ''
        o.append(f'<path d="{d}" fill="none" stroke="{MUT}" stroke-width="1.6" marker-end="url(#ar)"{da}/>')
        if lb:
            segs = [(pts[i], pts[i+1]) for i in range(len(pts)-1)]
            tot = sum(abs(b[0]-a[0])+abs(b[1]-a[1]) for a, b in segs) or 1
            run, mx, my = 0.0, pts[0][0], pts[0][1]
            for a, b in segs:
                L = abs(b[0]-a[0])+abs(b[1]-a[1])
                if run + L >= tot*tf:
                    t = (tot*tf - run)/L if L else 0
                    mx, my = a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t
                    break
                run += L
            tw = len(lb)*5.8 + 12
            o.append(f'<rect x="{mx-tw/2:.0f}" y="{my-17:.0f}" width="{tw:.0f}" height="15" rx="3" '
                     f'fill="#FFFFFF" opacity="0.95"/>')
            o.append(f'<text x="{mx:.0f}" y="{my-6:.0f}" font-size="10.5" fill="{MUT}" '
                     f'text-anchor="middle">{E(lb)}</text>')
    for nid, lb, x, y, s, ic, png, f in ICONS:
        bd = ' stroke="#C6CFD8" stroke-width="1.5"' if f.upper() == "#FFFFFF" else ''
        o.append(f'<rect x="{x}" y="{y}" width="{s}" height="{s}" rx="7" fill="{f}"{bd}/>')
        pad = s*0.16
        o.append(f'<image x="{x+pad:.0f}" y="{y+pad:.0f}" width="{s-2*pad:.0f}" height="{s-2*pad:.0f}" '
                 f'xlink:href="{uri(png)}" preserveAspectRatio="xMidYMid meet"/>')
        for i, line in enumerate(lb.split("|")):
            o.append(f'<text x="{x+s/2:.0f}" y="{y+s+13+i*12:.0f}" font-size="10" fill="{INK}" '
                     f'text-anchor="middle">{E(line)}</text>')
    words, line, lines = NOTE.split(), "", []
    for wd in words:
        if len(line) + len(wd) > 185:
            lines.append(line); line = wd
        else:
            line = (line + " " + wd).strip()
    lines.append(line)
    for i, ln in enumerate(lines):
        o.append(f'<text x="40" y="{1322+i*16}" font-size="11" fill="{MUT}">{E(ln)}</text>')
    o.append('</svg>')
    return "\n".join(o)

here = pathlib.Path(__file__).parent
root = sys.argv[1] if len(sys.argv) > 1 else None
if not root:
    import diagrams
    root = pathlib.Path(diagrams.__file__).parent.parent / "resources"
(here/"architecture.drawio").write_text(build_drawio(), encoding="utf-8")
(here/"architecture.svg").write_text(build_svg(root), encoding="utf-8")
print("đã sinh architecture.drawio và architecture.svg")
