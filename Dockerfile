# Use an official lightweight web server image
FROM nginx:alpine

# Copy static HTML files into Nginx web root
COPY . /usr/share/nginx/html

# Expose port 80 for the container
EXPOSE 80

# Start Nginx server
CMD ["nginx", "-g", "daemon off;"]