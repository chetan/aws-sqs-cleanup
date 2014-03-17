# aws-sqs-cleanup
A simple daemon for removing EC2 instances from Chef when an Auto Scaling Group termination notice
is received on an SQS queue.

### Install

```
$ git clone https://github.com/chetan/aws-sqs-cleanup.git
$ cd aws-sqs-cleanup
$ bundle install
```

### Configure

You must export the following environment variables (or add them to the
command line):

 * AWS_ACCESS_KEY_ID
 * AWS_SECRET_ACCESS_KEY
 * AWS_QUEUE_NAME
 * AWS_TOPIC_ARN (optional)

AWS_QUEUE_NAME can be the full queue name or the name of the auto scaling group.

If AWS_TOPIC_ARN is available, then the given topic will be notified of the
restart event. The message body will be as in the sample below.

### Run

```
$ ./daemon.rb
or
$ ./daemon.rb 2>&1 >cleanup_daemon.log &
```
