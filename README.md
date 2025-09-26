## README

Droplets are integrations between third-party services and Fluid. This is a repository intended to be used as an example for creating Droplets.

Documentation can be found in the [project's GitHub page](https://fluid-commerce.github.io/droplet-template/)

## Production environment

### Google cloud infrastructure

- Google Cloud Run (Web)
- Google Cloud Storage (Terraform)
- Google Cloud SQL (postgreSQL)
- Google Cloud Build (CI/CD)
- Google Cloud Compute Engine (jobs console)
- Artifact Registry (Docker)

web: Google Cloud Run name `fluid-droplet-NAME`

jobs console: Google Cloud Compute Engine name `fluid-droplet-NAME-jobs-console`

### Deploy to google cloud

Run github action to deploy to google cloud `deploy production`
or run the following command to deploy to google cloud  

`gcloud beta builds submit --config cloudbuild-production.yml --region=us-west3 --substitutions=COMMIT_SHA=$(git rev-parse --short HEAD),_TIMESTAMP=$(date +%Y%m%d%H%M%S) --project=fluid-417204 .`

### Add environment variables to google cloud

Add environment variables to google cloud `add-update-env-gcloud.sh` and run the following command to add environment variables to google cloud
`sh add-update-env-gcloud.sh`

### Technology Stack

![PostgreSQL 17](https://img.shields.io/badge/PostgreSQL-17-336791?logo=postgresql&logoColor=white)
![Ruby](https://img.shields.io/badge/Ruby-3.4.2-CC342D?logo=ruby&logoColor=white)
![Rails](https://img.shields.io/badge/Rails-8.0.2-CC0000?logo=ruby-on-rails&logoColor=white)
![Node.js](https://img.shields.io/badge/Node.js-23.8.0-339933?logo=node.js&logoColor=white)
![Yarn](https://img.shields.io/badge/Yarn-4.7.0-2C8EBB?logo=yarn&logoColor=white)
![Font Awesome](https://img.shields.io/badge/Font_Awesome-6.7.2-528DD7?logo=fontawesome&logoColor=white)
![Tailwind CSS 4.0](https://img.shields.io/badge/Tailwind_CSS-4.0-38B2AC?logo=tailwindcss&logoColor=white)
<br>

## Local environment

### Running locally

Install dependencies with `bundle install` and `yarn install`
and install foreman with `gem install foreman`  
Just the rails server (port 3000)<br>
`foreman start -f Procfile.dev`

Running everything (port 3200)<br>
`bin/dev`

### Running locally with docker

This approach allows you to use your local PostgreSQL instance with Docker.

**Prerequisites:**
- Docker installed
- PostgreSQL running locally
- Database `droplet_template_development` created

**Step-by-step setup:**

1. **Copy environment file:**
   ```bash
   cp .env.local.example .env
   ```

2. **Edit `.env` file with your database credentials:**
   ```bash
   # Required
   SECRET_KEY_BASE=your_secret_key_here

   # Database connection (use your local PostgreSQL)
   DATABASE_URL=postgresql://username:password@host.docker.internal:5432/droplet_template_development

   # Environment
   RAILS_ENV=development
   ```

3. **Build the Docker image:**
   ```bash
   docker build -t droplet-template .
   ```

4. **Run database migrations (if needed):**
   ```bash
   # If you haven't run migrations yet, run them first
   docker run --env-file .env -e RAILS_ENV=development droplet-template bin/rails db:migrate
   ```

5. **Run the container:**
   ```bash
   docker run -p 3200:80 --env-file .env -e RAILS_ENV=development droplet-template
   ```

6. **Access the application:**
   Open your browser and go to: `http://localhost:3200`

**Notes:**
- Use `host.docker.internal` instead of `localhost` in DATABASE_URL for Docker to access your local PostgreSQL
- The application will run on port 3200 (mapped from container port 80)
- Make sure your PostgreSQL is running and accessible before starting the container

### License

MIT License

Copyright (c) 2025 Fluid Commerce

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
