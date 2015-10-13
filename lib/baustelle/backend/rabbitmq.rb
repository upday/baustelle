module Baustelle
  module Backend
    class RabbitMQ
      def initialize(name, options, vpc:)
        @name = name
        @options = options
        @vpc = vpc
        @region = region
      end

      def build(template)

        options.fetch('ami').each do |region, ami|
          template.add_to_region_mapping "BackendAMIs", region, ami_name, ami
        end

        template.resource lc = "RabbitMQ#{template.camelize(name)}LaunchConfiguration",
                          Type: 'AWS::AutoScaling::LaunchConfiguration',
                          Properties: {
                            AssociatePublicIpAddress: true,
                            ImageId: template.find_in_regional_mapping('BackendAMIs', ami_name),
                            InstanceType: options.fetch('instance_type',
                                                        default_instance_type)
                          }

        template.resource elb = "RabbitMQ#{template.camelize(name)}ELB",
                          Type: 'AWS::ElasticLoadBalancing::LoadBalancer',
                          Properties: {
                            Subnets: vpc.zone_identifier,
                            Scheme: 'internal',
                            Listeners: [
                              {InstancePort: 5672, InstanceProtocol: 'tcp',
                               LoadBalancerPort: 5672, Protocol: 'tcp'}
                            ],
                            Tags: [
                              {Key: 'BaustelleBackend', Value: 'RabbitMQ'},
                              {Key: 'BaustelleName', Value: name}
                            ]
                          }

        template.resource "RabbitMQ#{template.camelize(name)}ASG",
                          Type: 'AWS::AutoScaling::AutoScalingGroup',
                          Properties: {
                            AvailabilityZones: vpc.availability_zones,
                            MinSize: options.fetch('cluster_size'),
                            MaxSize: options.fetch('cluster_size'),
                            DesiredCapacity: options.fetch('cluster_size'),
                            LoadBalancerNames: [template.ref(elb)],
                            VPCZoneIdentifier: vpc.zone_identifier,
                            LaunchConfigurationName: template.ref(lc),
                            Tags: [
                              {PropagateAtLaunch: true, Key: 'BaustelleBackend', Value: 'RabbitMQ'},
                              {PropagateAtLaunch: true, Key: 'BaustelleName', Value: template.camelize(name)},
                              {PropagateAtLaunch: true, Key: 'Name', Value: "RabbitMQ#{template.camelize(name)}"},
                            ]
                          }
      end

      private

      attr_reader :name, :options, :region, :vpc

      def ami_name
        "rabbit_mq_#{name}"
      end

      def default_instance_type
        't2.small'
      end
    end
  end
end