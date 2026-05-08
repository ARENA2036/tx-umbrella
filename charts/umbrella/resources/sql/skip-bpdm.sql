DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM portal.company_applications ca
        JOIN portal.application_checklist ac 
            ON ca.id = ac.application_id
        WHERE ca.application_status_id = 7
          AND ac.application_checklist_entry_type_id = 8
          AND ac.application_checklist_entry_status_id = 2
    ) THEN
        CREATE TEMP TABLE tmp_target_applications AS
        SELECT ca.id,
                ca.checklist_process_id,
                ca.company_id
        FROM portal.company_applications ca
        JOIN portal.companies c
            ON c.id = ca.company_id
        WHERE EXISTS (
            SELECT 1
            FROM portal.companies c2
            WHERE c2.business_partner_number = c.business_partner_number
            AND ca.application_status_id = 7 
        );


        UPDATE portal.application_checklist ac
        SET application_checklist_entry_status_id = 3
        FROM tmp_target_applications ta
        WHERE ac.application_id = ta.id
        AND ac.application_checklist_entry_type_id = 8;

        UPDATE portal.process_steps ps
        SET process_step_status_id = 3
        FROM tmp_target_applications ta
        WHERE ps.process_id = ta.checklist_process_id
        AND ps.process_step_type_id = 44;

        UPDATE portal.company_applications ca
        SET application_status_id = 8
        FROM tmp_target_applications ta
        WHERE ca.company_id = ta.company_id;

        DROP TABLE IF EXISTS tmp_target_applications;

        COMMIT;
    END IF;
END $$;