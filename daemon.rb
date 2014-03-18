#!/usr/bin/env ruby

AWS_ACCESS_KEY = ENV["AWS_ACCESS_KEY_ID"]
AWS_SECRET_KEY = ENV["AWS_SECRET_ACCESS_KEY"]
AWS_QUEUE_NAME = ENV["AWS_QUEUE_NAME"]
AWS_TOPIC_NAME = ENV["AWS_TOPIC_ARN"]

require "aws-sdk"
require "multi_json"

def send_alert(log)
  return if AWS_TOPIC_NAME.nil? or AWS_TOPIC_NAME.empty?

  topic = AWS::SNS.new.topics[AWS_TOPIC_NAME]
  if topic.nil? then
    STDERR.puts "topic '#{AWS_TOPIC_NAME}' doesn't exist!"
    return
  end

  topic.publish(log, :subject => "[aws-sqs-cleanup] terminated instance removed from chef")
  puts "   sent notification to #{AWS_TOPIC_NAME}"
end

def validate_queues()

  queue_names = []
  if AWS_QUEUE_NAME.include?(",") then
    queue_names = AWS_QUEUE_NAME.split(/,/).map{ |s| s.strip }
  else
    queue_names << AWS_QUEUE_NAME.strip
  end

  queues = []

  sqs = AWS::SQS.new
  sqs_queues = sqs.queues

  queue_names.each do |qn|
    begin
      queues << sqs_queues.named(qn)
    rescue
      # search for queue
      found = false
      sqs_queues.each do |q|
        name = q.arn.split(/:/).last
        if name =~ /^#{qn}-SQSQueueScalingNotification-.*$/ then
          queues << q
          found = true
          break
        end
      end
      if !found then
        raise "Unable to locate queue for #{qn}"
      end
    end
  end

  return queues
end

def delete_chef_node(instance)
  ret = `knife search node 'ec2_instance_id:#{instance}'  | grep 'Node Name'`
  if ret =~ /Node Name:\s+(.*?)/ then
    node = $1
    puts "#{instance}: found matching chef node: #{node}; deleting"
    system("knife node delete #{node}")
    system("knife client delete #{node}")
    return true
  end

  puts "#{instance}: unable to find matching chef node"
  return false
end

def process_message(queue, msg)
  b = MultiJson.load(msg.body)
  m = MultiJson.load(b["Message"])

  if m["Event"] == "autoscaling:EC2_INSTANCE_TERMINATE" then
    i = m["EC2InstanceId"]
    puts queue.arn.split(/:/).last + ": #{i} was terminated, removing from chef"
    if delete_chef_node(i) then
      send_alert queue.arn.split(/:/).last + ": #{i} was terminated, removed from chef"
    else
      send_alert queue.arn.split(/:/).last + ": #{i} was terminated, but unable to find in chef"
    end
  end
end

################################################################################
# validate config
err = false
if !AWS_ACCESS_KEY or AWS_ACCESS_KEY.empty? then
   STDERR.puts "ERROR: missing required ENV variable 'AWS_ACCESS_KEY_ID'"
   err = true
end
if !AWS_SECRET_KEY or AWS_SECRET_KEY.empty? then
   STDERR.puts "ERROR: missing required ENV variable 'AWS_SECRET_ACCESS_KEY'"
   err = true
end
if !AWS_QUEUE_NAME or AWS_QUEUE_NAME.empty? then
   STDERR.puts "ERROR: missing required ENV variable 'AWS_QUEUE_NAME'"
   err = true
end
exit 1 if err


################################################################################
# main
$0 = "aws-sqs-cleanup-daemon [queue=#{AWS_QUEUE_NAME}]"
AWS.config(
  :access_key_id => AWS_ACCESS_KEY,
  :secret_access_key => AWS_SECRET_KEY)

queues = validate_queues()

puts "Listening on SQS queue(s) '#{AWS_QUEUE_NAME}' for termination events..."

# poll each queue every 60 seconds
begin
  loop do
    queues.each do |q|
      messages = q.receive_message(:limit => 10, :visibility_timeout => 10)
      messages = [messages] if not messages.kind_of? Array
      messages.each do |msg|
        next if msg.nil?
        process_message(q, msg)
        msg.delete # comment out for testing (keeps message in queue)
      end
      exit
    end
    sleep 60
  end
rescue Interrupt => ex
end

# auto scaling message format:
#
# {
#   "Type" : "Notification",
#   "MessageId" : "17c0d085-596b-5d92-9de5-9b1978b445b1",
#   "TopicArn" : "arn:aws:sns:us-east-1:1234567890:asg-name-SNSTopicScalingNotification-YS8XM0BUMZ45",
#   "Subject" : "Auto Scaling: termination for group \"asg-name-WebGroupOnDemand-6FQ95AZW2XBR\"",
#   "Message" : "{\"StatusCode\":\"InProgress\",\"Service\":\"AWS Auto Scaling\",\"AutoScalingGroupName\":\"asg-name-WebGroupOnDemand-6FQ95AZW2XBR\",\"Description\":\"Terminating EC2 instance: i-09809828\",\"ActivityId\":\"59e13021-da94-4e1b-a4dd-d2db11a69b1b\",\"Event\":\"autoscaling:EC2_INSTANCE_TERMINATE\",\"Details\":{\"Availability Zone\":\"us-east-1d\"},\"AutoScalingGroupARN\":\"arn:aws:autoscaling:us-east-1:knife node delete:autoScalingGroup:a882513e-8a66-4506-8493-d1c7e43e8b26:autoScalingGroupName/asg-name-WebGroupOnDemand-6FQ95AZW2XBR\",\"Progress\":50,\"Time\":\"2014-03-13T21:14:07.929Z\",\"AccountId\":\"knife node delete\",\"RequestId\":\"59e13021-da94-4e1b-a4dd-d2db11a69b1b\",\"StatusMessage\":\"\",\"EndTime\":\"2014-03-13T21:14:07.929Z\",\"EC2InstanceId\":\"i-09809828\",\"StartTime\":\"2014-03-13T21:14:04.746Z\",\"Cause\":\"At 2014-03-13T21:14:04Z an instance was taken out of service in response to a system health-check.\"}",
#   "Timestamp" : "2014-03-13T21:14:07.963Z",
#   "SignatureVersion" : "1",
#   "Signature" : "ZwynrmmCdyXkKrLsMfuWcUA1C+1Bkd6yCFThuRQEhD/jlFrA+Zp3I4Q+BzvH197mAp9rTokJBkOk9svHEMucFxqJD0Idg942pt/D5sm4Qk/iZpCis5FZAYW7JNmPFgi6D5lrfpXKhyv8fQljY2EaOlgvbv2opHTdm3MLPwVsONVtsatMdGbsTec4lpGFVxg4LgjkrO4qIYpnH1f9VS6E1obzr4FkS48nfUgQARZKKGmHyF//enc4yNbpIvS3HajehXdJMgbscMaC6JXI5GG2YoicuwcFGyjnkAwn3KIP42GmCfPG/MIL5MSq2FXDSXJPfjEX5UW+EWLAdjTHi1JCaA==",
#   "SigningCertURL" : "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-e372f8ca30337fdb084e8ac449342c77.pem",
#   "UnsubscribeURL" : "https://sns.us-east-1.amazonaws.com/?Action=Unsubscribe&SubscriptionArn=arn:aws:sns:us-east-1:knife node delete:asg-name-SNSTopicScalingNotification-YS8XM0BUMZ45:11f48571-0a27-4b5f-bbd6-b2c3e90edcb5"
# }
