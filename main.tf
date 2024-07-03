provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "my_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name = "my-igw"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.my_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "private-subnet"
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.my_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_igw.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_security_group" "nginx_sg" {
  name        = "nginx-security-group"
  description = "Security group for nginx instances"
  vpc_id      = aws_vpc.my_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "nginx_alb" {
  name               = "nginx-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.nginx_sg.id]

  subnets = [
    aws_subnet.public_subnet.id,
    aws_subnet.private_subnet.id,
  ]

  tags = {
    Name = "nginx-alb"
  }
}


resource "aws_lb_target_group" "nginx_target_group" {
  name        = "nginx-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.my_vpc.id
  target_type = "instance"

  tags = {
    Name = "nginx-target-group"
  }
}

resource "aws_lb_listener" "nginx_listener" {
  load_balancer_arn = aws_lb.nginx_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx_target_group.arn
  }
}

resource "aws_launch_configuration" "nginx_lc" {
  name_prefix                 = "nginx-lc"
  image_id                    = "ami-06c68f701d8090592"
  instance_type               = "t2.micro"
  security_groups             = [aws_security_group.nginx_sg.id]
  associate_public_ip_address = false
  iam_instance_profile        = "ssm"
  user_data                   = <<-EOF
                                  #!/bin/bash
                                  sudo yum install nginx -y
                                  sudo systemctl start nginx
                                  sudo systemctl enable nginx
                                  echo "<h1>nginx is running!</h1>" | sudo tee /usr/share/nginx/html/index.html
                                  sudo systemctl restart nginx
                                  EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "nginx_asg" {
  launch_configuration = aws_launch_configuration.nginx_lc.name
  desired_capacity     = 2
  max_size             = 4
  min_size             = 2
  vpc_zone_identifier  = [aws_subnet.private_subnet.id]

  target_group_arns = [aws_lb_target_group.nginx_target_group.arn]

  tag {
    key                 = "Name"
    value               = "nginx-server"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "test"
    propagate_at_launch = true
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300
}

resource "aws_autoscaling_policy" "cpu_scaling_policy" {
  name        = "cpu-scaling-policy"
  policy_type = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 80.0
  }

  autoscaling_group_name = aws_autoscaling_group.nginx_asg.name
}

resource "aws_instance" "nginx_instance" {
  instance_type = "t2.micro"
  ami           = "ami-06c68f701d8090592"
  subnet_id     = aws_subnet.private_subnet.id
}


resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "my_nat_gateway" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
}

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.my_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.my_nat_gateway.id
  }

  tags = {
    Name = "private-route-table"
  }
}

resource "aws_route_table_association" "private_subnet_association" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_route_table.id
}

