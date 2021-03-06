module Baustelle
  class StackTemplate
    PARALLEL_EB_UPDATES = ENV.fetch('PARALLEL_EB_UPDATES', 2).to_i

    def initialize(config)
      @config = config
    end

    def build(name, region, bucket_name, main_template_uuid, template: CloudFormation::Template.new)
      # Prepare VPC
      vpc = CloudFormation::VPC.apply(template, vpc_name: name,
                                      cidr_block: config.fetch('vpc').fetch('cidr'),
                                      subnets: config.fetch('vpc').fetch('subnets'))

      peer_vpcs = config.fetch('vpc').fetch('peers', {}).map do |name, peer_config|
        CloudFormation::PeerVPC.apply(template, vpc, name,
                                      peer_config)
      end

      internal_dns_zones = [CloudFormation::InternalDNS.zone(template, stack_name: name,
                                                            vpcs: [vpc],
                                                            root_domain: "baustelle.internal"),
                           CloudFormation::InternalDNS.zone(template, stack_name: name,
                                                            vpcs: peer_vpcs,
                                                            root_domain: "#{name}.#{region}.baustelle.internal",
                                                            type: 'Peering')]


      template.resource "GlobalSecurityGroup",
                        Type: "AWS::EC2::SecurityGroup",
                        Properties: {
                          VpcId: vpc.id,
                          GroupDescription: "#{name} baustelle stack global Security Group",
                          SecurityGroupIngress: [
                            {IpProtocol: 'tcp', FromPort: 80, ToPort: 80, SourceSecurityGroupId: template.ref('ELBSecurityGroup')},
                          ] + ([vpc] + peer_vpcs).map { |vpc|
                            {IpProtocol: 'tcp', FromPort: 0, ToPort: 65535, CidrIp: vpc.cidr} }
                        }

      template.resource "ELBSecurityGroup",
                        Type: "AWS::EC2::SecurityGroup",
                        Properties: {
                          VpcId: vpc.id,
                          GroupDescription: "#{name} baustelle stack ELB Security Group",
                          SecurityGroupIngress: [
                            {IpProtocol: 'tcp', FromPort: 0, ToPort: 65535, CidrIp: '0.0.0.0/0'}
                          ]
                        }

      global_iam_role = CloudFormation::IAMRole.new('', {'describe_tags' => {
                                                           'action' => 'ec2:DescribeTags'
                                                         },
                                                         'describe_instances' => {
                                                           'action' => 'ec2:DescribeInstances'
                                                         },
                                                         'elastic_beanstalk_bucket_access' => {
                                                           'action' => ['s3:Get*', 's3:List*', 's3:PutObject'],
                                                           'resource' => [
                                                             "arn:aws:s3:::elasticbeanstalk-*-*",
                                                             "arn:aws:s3:::elasticbeanstalk-*-*/*",
                                                             "arn:aws:s3:::elasticbeanstalk-*-*-*",
                                                             "arn:aws:s3:::elasticbeanstalk-*-*-*/*"
                                                           ]
                                                         }
                                                        }).apply(template)

      if bastion_config = config['bastion']
        Baustelle::CloudFormation::BastionHost.apply(template, bastion_config, vpc: vpc, stack_name: name, parent_iam_role: global_iam_role)
      end

      # It is used to chain updates. There is high likehood we hit AWS API rate limit
      # if we create/update all environments at once
      previous_eb_env =  nil

      applications = Baustelle::Config.applications(config).sort_by { |app_name| app_name}.each.map do |app_name|
        app = CloudFormation::ApplicationStack.new(name, app_name, bucket_name, main_template_uuid, previous_eb_env)
        previous_eb_env = app.canonical_name
        app.apply(template, vpc)
        app
      end

      # For every environemnt
      Baustelle::Config.environments(config).each do |env_name|
        env_config = Baustelle::Config.for_environment(config, env_name)

        # Create backends

        environment_backends = Hash.new { |h,k| h[k] = {} }

        (env_config['backends'] || {}).inject(environment_backends) do |acc, (type, backends)|
          backend_klass = Baustelle::Backend.const_get(type)

          backends.each do |backend_name, options|
            backend_full_name = [env_name, backend_name].join('_')
            acc[type][backend_name] = backend = backend_klass.new(backend_full_name, options, vpc: vpc,
                                                                  parent_iam_role: global_iam_role,
                                                                  internal_dns: internal_dns_zones,
                                                                  env_name: env_name)
            backend.build(template)
          end

          environment_backends
        end

        # Create applications

        applications.each do |app|
          app_config = Baustelle::Config.app_config(env_config, app.name)

          unless app_config.disabled?
            app.add_environment(template,name,region,env_name,vpc,app_config,env_config,environment_backends)
          end
        end
      end
      template
    end

    private

    attr_reader :config
  end
end
