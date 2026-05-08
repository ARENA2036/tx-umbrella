DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM portal.company_applications ca
        JOIN portal.application_checklist ac 
            ON ca.id = ac.application_id
        WHERE ca.application_status_id = 7
          AND ac.application_checklist_entry_type_id = 3
          AND ac.application_checklist_entry_status_id = 4
    ) THEN
        WITH applications AS (
		    SELECT distinct ca.id as Id, ca.checklist_process_id as ChecklistId
		    FROM portal.company_applications as ca
		             JOIN portal.application_checklist as ac ON ca.id = ac.application_id
		    where ca.application_status_id = 7 and ac.application_checklist_entry_type_id = 6 and ac.application_checklist_entry_status_id = 1
		    ),
		    updated AS (
		    UPDATE portal.application_checklist
		        SET application_checklist_entry_status_id = 3
		        WHERE application_id IN (SELECT Id FROM applications)
		        RETURNING *
		    )
		    INSERT INTO portal.process_steps (id, process_step_type_id, process_step_status_id, date_created, date_last_changed, process_id, message)
		    SELECT gen_random_uuid(), 12, 1, now(), NULL, a.ChecklistId, NULL
		    FROM applications a;
    END IF;
END $$;