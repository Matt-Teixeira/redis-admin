# start
docker start redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5
# stop
docker stop redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5
# remove containers
docker rm   redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5
# You removed the containers but kept the image
docker run -d --name redis-PROD    -p 6379:6379  redis:7-alpine
docker run -d --name redis-STAGING -p 6380:6379  redis:7-alpine
docker run -d --name redis_dev-0-4 -p 6381:6379  redis:7-alpine
docker run -d --name redis_dev-0-5 -p 6382:6379  redis:7-alpine

