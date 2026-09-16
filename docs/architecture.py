# -*- coding: utf-8 -*-
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.network import CloudFront, ElbApplicationLoadBalancer, NATGateway, InternetGateway
from diagrams.aws.storage import S3, EFS
from diagrams.aws.compute import EC2AutoScaling
from diagrams.aws.database import RDS, RDSInstance, Dynamodb
from diagrams.aws.integration import SQS
from diagrams.aws.management import Cloudwatch
from diagrams.onprem.client import Users

F = "DejaVu Sans"
g = {"fontname": F, "fontsize": "14", "pad": "0.4", "nodesep": "0.6",
     "ranksep": "0.85", "bgcolor": "white", "splines": "spline", "compound": "true"}
n = {"fontname": F, "fontsize": "11"}
e = {"fontname": F, "fontsize": "10", "color": "#5A6B7B"}
def cl(bg, col): return {"fontname": F, "fontsize": "12", "style": "rounded,dashed",
                         "penwidth": "1.6", "bgcolor": bg, "color": col, "margin": "14"}

with Diagram("", show=False, filename="architecture", direction="TB",
             outformat=["png", "svg"], graph_attr=g, node_attr=n, edge_attr=e):

    user = Users("Người dùng")

    with Cluster("AWS Cloud · ap-southeast-1", graph_attr=cl("#FAFBFC", "#232F3E")):
        with Cluster("biên · CloudFront + S3", graph_attr=cl("#F6F1FF", "#8C4FFF")):
            cf = CloudFront("CloudFront")
            s3 = S3("S3 · SPA tĩnh")

        with Cluster("VPC 10.0.0.0/16", graph_attr=cl("#FFFFFF", "#248814")):
            with Cluster("public subnet", graph_attr=cl("#F2F9F0", "#7AA116")):
                igw = InternetGateway("Internet GW")
                alb = ElbApplicationLoadBalancer("ALB public :80")
                nat = NATGateway("NAT Gateway")

            with Cluster("private subnet", graph_attr=cl("#F0F6FD", "#147EBA")):
                app = EC2AutoScaling("EC2 App tier + Worker\nASG 2–6 máy · warm pool")

            with Cluster("data subnet · không ra internet", graph_attr=cl("#FDF6EF", "#DD6B10")):
                proxy = RDS("RDS Proxy")
                efs   = EFS("EFS · access point")
                with Cluster("RDS PostgreSQL 16 · Multi-AZ", graph_attr=cl("#FFFFFF", "#2E27AD")):
                    rds_a = RDSInstance("primary · 1a")
                    rds_b = RDSInstance("standby · 1b")

        with Cluster("dịch vụ region · ngoài VPC", graph_attr=cl("#FFFFFF", "#9AA7B4")):
            ddb = Dynamodb("DynamoDB\naccept store")
            sqs = SQS("SQS FIFO + DLQ")
            cw  = Cloudwatch("CloudWatch")

    user >> Edge(label="HTTPS") >> cf
    cf >> Edge(label="OAC") >> s3
    cf >> Edge(label="/api/*") >> alb
    alb >> Edge(label="8080 · /ready") >> app

    app >> Edge(label="1 · PutItem\nchống trùng") >> ddb
    app >> Edge(label="2 · message\n3 · long poll") >> sqs
    app >> Edge(style="dotted") >> cw
    app >> Edge(label="4 · commit rồi\nmới xoá message") >> proxy
    app >> Edge(label="NFS · TLS") >> efs
    app >> Edge(label="egress", style="dashed") >> nat
    nat >> Edge(style="dashed") >> igw
    proxy >> rds_a
    proxy >> rds_b
