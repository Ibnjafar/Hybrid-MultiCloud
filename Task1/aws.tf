provider "aws" {
  region  = "ap-south-1"
  profile = "terauser"
}

data "aws_vpc" "current_vpc" {
	default = true
}

locals {
	vpc_id = data.aws_vpc.current_vpc.id
}

resource "tls_private_key" "ec2_private_key" {
algorithm = "RSA"
rsa_bits  = 4096
}

resource "local_file" "private_key" {
content = tls_private_key.ec2_private_key.private_key_pem

filename = "mywebserver.pem"
file_permission = 0400
}

resource "aws_key_pair" "ec2_private_key" {
key_name   = "mywebserver"
public_key = tls_private_key.ec2_private_key.public_key_openssh
}

# creating security group with access to ssh , http and ping
resource "aws_security_group" "allow_http_ssh_in" {
  name        = "allow_http_ssh"
  description = "Allow http/tcp , ping(icmp) and ssh inbound traffic"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
  		description = "ping icmp potocol"
  		from_port = -1
  		to_port   = -1
  		protocol  = "icmp"
  		cidr_blocks = ["0.0.0.0/0"] 
  }
  #outgoing traffic
  egress {
  		from_port = 0
  		to_port   = 0
  		protocol  = "-1"
  		cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "allow_http_ssh_ping"
  }
}

# creating aws instance

resource "aws_instance" "myinstance" {
  ami           = "ami-052c08d70def0ac62"
  instance_type = "t2.micro"
  key_name      = aws_key_pair.ec2_private_key.key_name
  vpc_security_group_ids = [ aws_security_group.allow_http_ssh_in.id ]
  availability_zone = "ap-south-1b"

  tags = {
    Name = "myterraos"
  }
  connection {
  	type = "ssh"
  	user = "ec2-user"
  	host = aws_instance.myinstance.public_ip
  	port = 22
  	private_key = tls_private_key.ec2_private_key.private_key_pem
  }
  provisioner "remote-exec" {
        inline = [
	"sudo yum install httpd -y", 
	"sudo yum install git -y",
	"sudo systemctl start httpd",  
	"sudo systemctl enable httpd"
        ]
  }
}

# creating block storage volume of size 1gib
resource "aws_ebs_volume" "my_ebs_volume" {
  availability_zone = aws_instance.myinstance.availability_zone
  size              = 1
  tags = {
    Name = "myebsvol1"
  }
}

# attaching ebs volume ebs_att to aws instance and mounting it
resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/xvdh"
  volume_id   = aws_ebs_volume.my_ebs_volume.id
  instance_id = aws_instance.myinstance.id
  force_detach = true

  connection {
  	type = "ssh"
  	user = "ec2-user"
  	host = aws_instance.myinstance.public_ip
  	port = 22
  	private_key = tls_private_key.ec2_private_key.private_key_pem
  }
  provisioner "remote-exec" {
        inline = [
        "sudo mkfs.ext4 /dev/xvdh",
        "sudo mount /dev/xvdh /var/www/html",
		"sudo rm -rf /var/www/html/*", 
		"sudo git clone https://github.com/Ibnjafar/webserver.git /var/www/html/"
        ]
  }
  provisioner "remote-exec"{
  	when = destroy
  	inline = [
  	"sudo umount /var/www/html"]
  }
}


#  Creation of S3 bucket
resource "aws_s3_bucket" "my_terabucket" {
bucket = "ubaidbucket"
acl    = "public-read"

provisioner "local-exec" {
	command = "git clone https://github.com/Ibnjafar/webserver.git  webrepo-image"
}

provisioner "local-exec" {
	when = destroy
	command = "echo Y | rmdir /s webrepo-image"
}

tags = {
Name  = "my_terra_bucket"
}
}
 
#  uploading images to s3 bucket my_tera_bucket
resource "aws_s3_bucket_object" "image_upload_to_my_terabucket"{
	bucket = aws_s3_bucket.my_terabucket.bucket
	key = "nature.jpg"
	source = "webrepo-image/images/nature.jpg"
	acl = "public-read"
}




locals {
	s3_origin_id = "S3-${aws_s3_bucket.my_terabucket.bucket}"
	image_url = "${aws_cloudfront_distribution.s3_distribution.domain_name}/${aws_s3_bucket_object.image_upload_to_my_terabucket.key}"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
	default_cache_behavior {
	allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
	cached_methods   = ["GET", "HEAD"]
	target_origin_id = "${local.s3_origin_id}"
	forwarded_values {
	query_string = false
	cookies {
	forward = "none"
	}
	}
viewer_protocol_policy = "allow-all"
}
enabled             = true

origin {
	domain_name = aws_s3_bucket.my_terabucket.bucket_domain_name
	origin_id = local.s3_origin_id
}

restrictions {
 geo_restriction {
	restriction_type = "none"
}
}
viewer_certificate {
	cloudfront_default_certificate = true
}
connection {
  	type = "ssh"
  	user = "ec2-user"
  	host = aws_instance.myinstance.public_ip
  	port = 22
  	private_key = tls_private_key.ec2_private_key.private_key_pem
  }

provisioner "remote-exec" {
	inline = [
	"sudo su <<EOF ",
	"echo \"<img src='http://${self.domain_name}/${aws_s3_bucket_object.image_upload_to_my_terabucket.key}'>\"  >> /var/www/html/index.html",
	"EOF"
	]
}
}
