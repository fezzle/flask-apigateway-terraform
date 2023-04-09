# An example deployment of a Lambda function function fronted by an API Gateway

This is a simple example of a Lambda function that is fronted by an API Gateway. 

The Lambda function is written in Python and provides a Flask environment for application development.

## Deployment
The deployment occurs entirely through terraform.  The lambda requires a layer for python depednencies.

For how this is done, see https://dev.to/matthewvielkind/creating-python-aws-lambda-layers-with-docker-4376

