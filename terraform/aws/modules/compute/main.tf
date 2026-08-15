# ALB in public subnets, application instances in private ones.
#
# The zero-downtime settings have direct equivalents here to the ones in the
# Kubernetes manifests, and they matter for the same reasons: the target group's
# deregistration delay is the ALB's version of a preStop hook, and the ASG's
# instance refresh with min_healthy_percentage = 100 is maxUnavailable: 0.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-${var.environment}-alb"
  description = "Ingress to the public load balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-${var.environment}-alb" }
}

resource "aws_security_group" "app" {
  name        = "${var.name}-${var.environment}-app"
  description = "Application instances"
  vpc_id      = var.vpc_id

  # Only the load balancer may reach the application. Referencing the ALB's
  # security group rather than a CIDR keeps that true even when subnets change.
  ingress {
    description     = "Application traffic from the load balancer only"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-${var.environment}-app" }
}

resource "aws_lb" "this" {
  name               = "${var.name}-${var.environment}"
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # Must exceed the application's own drain window, or the ALB cuts connections
  # the application was still willing to finish.
  idle_timeout = 60

  enable_deletion_protection = false

  tags = { Name = "${var.name}-${var.environment}" }
}

resource "aws_lb_target_group" "this" {
  name     = "${var.name}-${var.environment}"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  # The ALB equivalent of a preStop hook: keep sending in-flight responses to a
  # target that has left the group, rather than resetting them.
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.name}-${var.environment}" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-${var.environment}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name}-${var.environment}-app"
      Role = "app"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-${var.environment}"
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.this.arn]

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.min_size

  # ELB health checks, not EC2 ones. EC2 checks only notice a dead instance;
  # ELB checks notice an instance whose application stopped answering, which is
  # the failure that actually happens.
  health_check_type         = "ELB"
  health_check_grace_period = 90

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  # The ASG's answer to maxUnavailable: 0. Capacity never dips below 100% of
  # desired during a refresh -- new instances come up and pass health checks
  # before any old one is terminated.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 90
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-${var.environment}-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
