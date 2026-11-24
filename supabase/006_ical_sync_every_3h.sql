-- Calendar sync runs every 3 hours (minute 7, UTC hours 0,3,...,21), same edge function as the "sync now" button
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'ical-sync'), schedule := '7 */3 * * *');
