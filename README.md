EC2 instance list utility
=========================

This is a simple console utility that visualizes a list of your EC2 instances in a easy-to-read view. 
It enlists your instances groupped by VPC and Subnets, providing only essential information about each of them.
Also it has an option to provide detailed information about a specific instance.

The utility may be used as a light-weight replacement for browsing instances in AWS Console, ElasticFox and other graphical tools.

Dependencies
------------

It is written and tested with Ruby 2.0, but it should run with newer version of Ruby as well. 
Please report about any incompatibilities you noticed. Also there are two gems it requires, they are defined in Gemfile:
* AWS SDK for Ruby v.2 (http://docs.aws.amazon.com/sdkforruby/api/)
* Colorize (https://github.com/fazibear/colorize)

Notes on the output
-------------------

Several tricks are used to make the brief information about an instance compact but still useful. 
First, the instance state is represented by an icon (UTF-graphics is used for console). 
Some binary attributes (Is it a spot instance? Is it a Windows instance? Is monitoring enabled?) are shown in form of one-character flags.
Private IP address is not shown for non-VPC instances (where it makes very little sense for user), etc.

There are also few trade-offs in the detailed view to make the information easy to read. 
For instance the key pair name is not printed for Windows instances (where it is used to decypher the initial Administrator password, 
as it is generally one-time operation and it is usually managed by AWS Console). The root device type is not printed as well, as 
the ephemeral roots are very rare nowadays. 
For security groups I allocated a whole line, as OpsWorks-generated instances usually have a bunch of them.

If you have some ideas how to improve the presentation of the data - don't hesitate and contact me. Patches are welcome too!
