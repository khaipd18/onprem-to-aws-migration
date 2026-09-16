# -*- coding: utf-8 -*-
"""
Nguồn duy nhất của sơ đồ kiến trúc. Sinh ra:
  docs/architecture.drawio  — shape AWS4, mở sửa bằng app.diagrams.net
  docs/architecture.svg     — cùng toạ độ, nhúng icon AWS chính thức

Chạy:  python docs/architecture_gen.py [đường-dẫn-thư-mục-icon]
Icon lấy từ package `diagrams` (pip install diagrams) — thư mục site-packages/resources.
"""
import sys, os, html, base64, pathlib

def E(s): return html.escape(s, quote=True)

W, H = 1700, 1210
INK, MUT = "#232F3E", "#5A6B7B"
NET, STO, CMP, DB, INT = "#8C4FFF", "#7AA116", "#ED7100", "#C925D1", "#E7157B"

# id, nhãn, x, y, w, h, loại, grIcon, màu
BOXES = [
 ("cloud", "AWS Cloud",                        170,  60, 1400, 1090, "aws", "group_aws_cloud",    INK),
 ("region","Region  ap-southeast-1",           370, 110, 1180, 1020, "aws", "group_region",       "#147EBA"),
 ("vpc",   "VPC  10.0.0.0/16",                 540, 170,  830,  910, "aws", "group_vpc2",         "#248814"),
 ("az_a",  "Availability Zone  ap-southeast-1a",570, 250, 370,  800, "az",  "",                   "#147EBA"),
 ("az_b",  "Availability Zone  ap-southeast-1b",980, 250, 370,  800, "az",  "",                   "#147EBA"),
 ("pub_a", "public subnet  10.0.0.0/24",       590, 310,  330,  205, "aws", "group_public_subnet", STO),
 ("pub_b", "public subnet  10.0.1.0/24",      1000, 310,  330,  205, "aws", "group_public_subnet", STO),
 ("prv_a", "private subnet  10.0.10.0/24",     590, 545,  330,  190, "aws", "group_private_subnet","#00A4A6"),
 ("prv_b", "private subnet  10.0.11.0/24",    1000, 545,  330,  190, "aws", "group_private_subnet","#00A4A6"),
 ("dat_a", "data subnet  10.0.20.0/24",        590, 775,  330,  255, "aws", "group_private_subnet","#DD6B10"),
 ("dat_b", "data subnet  10.0.21.0/24",       1000, 775,  330,  255, "aws", "group_private_subnet","#DD6B10"),
]
# thanh trải ngang hai AZ
SPANS = [
 ("alb", "Application Load Balancer  ·  public :80  ·  sg-alb-public", 610, 348, 700,  60, NET, "#F6F1FF"),
 ("asg", "Auto Scaling group  ·  2–6 máy  ·  warm pool  ·  sg-app",    610, 578, 700, 140, CMP, "#FEF3EC"),
 ("prx", "RDS Proxy  ·  TLS  ·  sg-rds-proxy",                          610, 808, 700,  56, DB,  "#FBF0FC"),
]
# id, nhãn, x, y, size, resIcon(drawio), icon png, màu nền
ICONS = [
 ("users","Người dùng",             60, 600, 78, "users",           "onprem/client/users.png",                   "#FFFFFF"),
 ("cf",   "CloudFront|edge · TLS", 218, 600, 78, "cloudfront",      "aws/network/cloudfront.png",                NET),
 ("s3",   "S3|SPA tĩnh",           420, 609, 60, "s3",              "aws/storage/simple-storage-service-s3.png", STO),
 ("igw",  "Internet Gateway",      925, 140, 60, "internet_gateway","aws/network/internet-gateway.png",          NET),
 ("nat",  "NAT Gateway",           600, 425, 60, "nat_gateway",     "aws/network/nat-gateway.png",               NET),
 ("ec2a", "EC2 App tier|+ Worker", 690, 600, 60, "ec2",             "aws/compute/ec2.png",                       CMP),
 ("ec2b", "EC2 App tier|+ Worker",1100, 600, 60, "ec2",             "aws/compute/ec2.png",                       CMP),
 ("rdsa", "RDS primary|sg-rds",    630, 880, 60, "rds",             "aws/database/rds-instance.png",             DB),
 ("mta",  "EFS mount target",      820, 880, 60, "elastic_file_system","aws/storage/elastic-file-system-efs.png",STO),
 ("rdsb", "RDS standby",          1040, 880, 60, "rds",             "aws/database/rds-instance.png",             DB),
 ("mtb",  "EFS mount target",     1230, 880, 60, "elastic_file_system","aws/storage/elastic-file-system-efs.png",STO),
 ("sqs",  "SQS FIFO|orders.fifo + DLQ",1430,300,60,"sqs",           "aws/integration/simple-queue-service-sqs.png",INT),
 ("ddb",  "DynamoDB|accept store",1430, 450, 60, "dynamodb",        "aws/database/dynamodb.png",                 DB),
 ("efs",  "EFS file system",      1430, 600, 60, "elastic_file_system","aws/storage/elastic-file-system-efs.png",STO),
 ("cw",   "CloudWatch",           1430, 750, 60, "cloudwatch_2",    "aws/management/cloudwatch.png",             INT),
]
# đường đi: các điểm gãy tuyệt đối, nhãn, nét đứt
EDGES = [
 ([(138,639),(218,639)],                               "HTTPS",        0, 0.5),
 ([(296,639),(420,639)],                               "origin · OAC", 0, 0.5),
 ([(257,600),(257,378),(610,378)],                     "/api/*",       0, 0.22),
 ([(955,200),(955,348)],                               "ingress",      0, 0.5),
 ([(740,408),(740,600)],                               "8080 · /ready",0, 0.72),
 ([(1130,408),(1130,600)],                             "8080 · /ready",0, 0.72),
 ([(690,615),(575,615),(575,455),(600,455)],           "egress",       1, 0.72),
 ([(600,455),(556,455),(556,230),(925,230),(925,170)], "",             1, 0.5),
 ([(1160,605),(1385,605),(1385,330),(1430,330)],       "2 · message · 3 · long poll", 0, 0.30),
 ([(1160,625),(1400,625),(1400,480),(1430,480)],       "1 · PutItem",  0, 0.30),
 ([(1160,650),(1370,650),(1370,780),(1430,780)],       "",             1, 0.5),
 ([(720,660),(720,808)],                               "4 · commit rồi xoá message", 0, 0.78),
 ([(1130,660),(1130,808)],                             "",             1, 0.5),
 ([(660,864),(660,880)],                               "5432",         0, 0.5),
 ([(1070,864),(1070,880)],                             "",             1, 0.5),
 ([(660,1000),(1070,1000)],                            "đồng bộ Multi-AZ", 1, 0.5),
 ([(750,630),(850,630),(850,880)],                     "NFS 2049 · TLS",0, 0.66),
 ([(1160,672),(1260,672),(1260,880)],                  "NFS 2049 · TLS",0, 0.60),
 ([(1430,660),(1350,660),(1350,760),(1260,760)],       "",             1, 0.5),
]
NOTE = ("Tầng data chỉ có route local — không gắn IGW, không gắn NAT, nên RDS và EFS mount target không có đường ra internet.   "
        "Một NAT Gateway duy nhất, đặt ở AZ 1a.   "
        "Hai EFS mount target thuộc cùng một file system.   "
        "API trả 202 Accepted, worker chỉ xoá message khỏi SQS sau khi transaction commit thành công.")

# ----------------------------------------------------------------- draw.io
AWSG = ("sketch=0;outlineConnect=0;gradientColor=none;html=1;whiteSpace=wrap;fontSize=12;fontStyle=0;"
        "container=1;pointerEvents=0;collapsible=0;recursiveResize=0;shape=mxgraph.aws4.group;"
        "grIcon=mxgraph.aws4.{i};strokeColor={c};fillColor=none;verticalAlign=top;align=left;"
        "spacingLeft=30;fontColor={c};dashed=0;")
AZG = ("rounded=0;html=1;whiteSpace=wrap;fillColor=none;strokeColor={c};dashed=1;dashPattern=8 6;"
       "verticalAlign=top;align=left;spacingLeft=10;spacingTop=2;fontSize=12;fontColor={c};"
       "container=1;pointerEvents=0;collapsible=0;")
SPN = ("rounded=1;arcSize=8;html=1;whiteSpace=wrap;fillColor={f};strokeColor={c};strokeWidth=1.5;"
       "dashed=1;dashPattern=6 4;verticalAlign=top;align=center;spacingTop=4;fontSize=11;fontColor={c};"
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
             f'<mxGeometry x="170" y="1160" width="1400" height="46" as="geometry"/></mxCell>')
    o += ['      </root></mxGraphModel>', '  </diagram>', '</mxfile>']
    return "\n".join(o)

# --------------------------------------------------------------------- SVG
def build_svg(icon_root):
    def data_uri(rel):
        p = pathlib.Path(icon_root) / rel
        return "data:image/png;base64," + base64.b64encode(p.read_bytes()).decode()

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
         f'viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
         f'font-family="Helvetica Neue, Helvetica, Arial, sans-serif">',
         f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>',
         f'<defs><marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
         f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{MUT}"/></marker></defs>']

    for bid, lb, x, y, w, h, kind, ic, c in BOXES:
        dash = ' stroke-dasharray="8 6"' if kind == "az" else ''
        o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="none" '
                 f'stroke="{c}" stroke-width="1.8"{dash}/>')
        o.append(f'<text x="{x+12}" y="{y+20}" font-size="12.5" font-weight="600" fill="{c}">{E(lb)}</text>')
    for sid, lb, x, y, w, h, c, f in SPANS:
        o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{f}" stroke="{c}" '
                 f'stroke-width="1.5" stroke-dasharray="6 4"/>')
        o.append(f'<text x="{x+w/2:.0f}" y="{y+18}" font-size="11.5" font-weight="600" fill="{c}" '
                 f'text-anchor="middle">{E(lb)}</text>')
    for pts, lb, dash, tfrac in EDGES:
        d = " ".join(("M" if i == 0 else "L") + f"{px},{py}" for i, (px, py) in enumerate(pts))
        da = ' stroke-dasharray="6 4"' if dash else ''
        o.append(f'<path d="{d}" fill="none" stroke="{MUT}" stroke-width="1.6" marker-end="url(#ar)"{da}/>')
        if lb:
            segs = [((pts[i][0]**2+0)**0, pts[i], pts[i+1]) for i in range(len(pts)-1)]
            tot = sum(abs(b[0]-a[0])+abs(b[1]-a[1]) for _, a, b in segs)
            run, mx, my = 0.0, pts[0][0], pts[0][1]
            for _, a, b in segs:
                L = abs(b[0]-a[0])+abs(b[1]-a[1])
                if run + L >= tot*tfrac:
                    t = (tot*tfrac - run)/L if L else 0
                    mx, my = a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t
                    break
                run += L
            tw = len(lb) * 5.9 + 12
            o.append(f'<rect x="{mx-tw/2:.0f}" y="{my-17:.0f}" width="{tw:.0f}" height="15" rx="3" fill="#FFFFFF" opacity="0.95"/>')
            o.append(f'<text x="{mx}" y="{my-6}" font-size="10.5" fill="{MUT}" text-anchor="middle">{E(lb)}</text>')
    for nid, lb, x, y, s, ic, png, f in ICONS:
        bd = f' stroke="#C6CFD8" stroke-width="1.5"' if f.upper() == "#FFFFFF" else ''
        o.append(f'<rect x="{x}" y="{y}" width="{s}" height="{s}" rx="7" fill="{f}"{bd}/>')
        pad = s * 0.16
        o.append(f'<image x="{x+pad:.0f}" y="{y+pad:.0f}" width="{s-2*pad:.0f}" height="{s-2*pad:.0f}" '
                 f'xlink:href="{data_uri(png)}" preserveAspectRatio="xMidYMid meet"/>')
        for i, line in enumerate(lb.split("|")):
            o.append(f'<text x="{x+s/2:.0f}" y="{y+s+14+i*13:.0f}" font-size="10.5" fill="{INK}" '
                     f'text-anchor="middle">{E(line)}</text>')
    words, line, lines = NOTE.split(), "", []
    for wd in words:
        if len(line) + len(wd) > 150:
            lines.append(line); line = wd
        else:
            line = (line + " " + wd).strip()
    lines.append(line)
    for i, ln in enumerate(lines):
        o.append(f'<text x="170" y="{1165+i*16}" font-size="11" fill="{MUT}">{E(ln)}</text>')
    o.append('</svg>')
    return "\n".join(o)


here = pathlib.Path(__file__).parent
icon_root = sys.argv[1] if len(sys.argv) > 1 else None
if not icon_root:
    import diagrams
    icon_root = pathlib.Path(diagrams.__file__).parent.parent / "resources"
(here / "architecture.drawio").write_text(build_drawio(), encoding="utf-8")
(here / "architecture.svg").write_text(build_svg(icon_root), encoding="utf-8")
print("đã sinh architecture.drawio và architecture.svg")
